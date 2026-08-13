package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"time"

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

const (
	identityAdmissionSignature = "signature"
	identityAdmissionExemption = "exemption"
	identityKeyRoleCurrent     = "current"
	identityKeyRolePrevious    = "previous"
	identityKeyRoleRecovery    = "recovery"
)

type identityProofResult struct {
	Accepted                         bool
	AdmissionMode                    string
	VerifiedKeyRole                  string
	DurableAdmissionIdentityVerified bool
	Generation                       int
	EnrollmentPubkey                 []byte
	VerifiedPubkey                   []byte
	ActivePubkey                     []byte
	RotationPubkey                   []byte
	RecoveryPubkey                   []byte
	RecoveryGrantedBy                string
	PreviousValidUntil               *time.Time
}

type durableIdentitySelection struct {
	VerificationPubkey []byte
	ActivePubkey       []byte
	Generation         int
	PreviousValidUntil *time.Time
	Found              bool
	Blocked            bool
}

// verifyIdentitySignature always tries a challenge-bound signature before it
// considers a temporary policy exemption. For an identity with no durable
// binding, an exact bearer owner may prove possession of the self-declared
// admission key; the caller persists that candidate only after the remaining
// admission checks succeed. This lets legacy provider IDs enroll in place.
func (s *Server) verifyIdentitySignature(ctx context.Context, initial AuthRequest, proof AuthRequest, retained AuthAttemptState, connectionAuth providerAuth) identityProofResult {
	signature, err := base64.StdEncoding.DecodeString(proof.IdentitySignature)
	signatureWellFormed := err == nil && len(signature) == ed25519.SignatureSize
	transcriptHash, err := base64.StdEncoding.DecodeString(proof.IdentityTranscriptSHA256)
	transcriptMatches := err == nil && len(transcriptHash) == sha256.Size &&
		bytes.Equal(transcriptHash, retained.InitialTranscriptSHA256[:])
	tuple := map[string]any{
		"auth_attempt_id":          proof.AuthAttemptID,
		"provider_id":              proof.ProviderID,
		"binary_version":           retained.BinaryVersion,
		"provider_ecdh_public_key": retained.ProviderECDHPublicKey,
		"transcript_sha256":        proof.IdentityTranscriptSHA256,
	}
	canonical, err := billing.CanonicalJSON(tuple)
	proofMaterialValid := signatureWellFormed && transcriptMatches && err == nil

	selection := s.durableIdentitySignatureSelection(ctx, initial)
	// Recovery response-loss replay: the coordinator may already have committed
	// the proposed key while the CLI still retains its recovery marker and
	// pending Keychain slot. Proof by the now-current key converges that exact
	// candidate without consulting policy again or advancing the generation.
	if proofMaterialValid && initial.ProviderAdmissionRecovery && selection.Found &&
		connectionAuth.validated && connectionAuth.providerID == initial.ProviderID &&
		len(initial.ProviderAdmissionPubkey) == ed25519.PublicKeySize &&
		bytes.Equal(initial.ProviderAdmissionPubkey, selection.ActivePubkey) &&
		ed25519.Verify(ed25519.PublicKey(selection.ActivePubkey), canonical, signature) {
		return identityProofResult{
			Accepted:                         true,
			AdmissionMode:                    identityAdmissionSignature,
			VerifiedKeyRole:                  identityKeyRoleCurrent,
			DurableAdmissionIdentityVerified: true,
			Generation:                       selection.Generation,
			VerifiedPubkey:                   append([]byte(nil), selection.ActivePubkey...),
			ActivePubkey:                     append([]byte(nil), selection.ActivePubkey...),
			PreviousValidUntil:               selection.PreviousValidUntil,
		}
	}
	if proofMaterialValid && !initial.ProviderAdmissionRecovery && selection.Found &&
		ed25519.Verify(ed25519.PublicKey(selection.VerificationPubkey), canonical, signature) {
		verifiedKeyRole := identityKeyRoleCurrent
		if !bytes.Equal(selection.VerificationPubkey, selection.ActivePubkey) {
			verifiedKeyRole = identityKeyRolePrevious
		}
		result := identityProofResult{
			Accepted:                         true,
			AdmissionMode:                    identityAdmissionSignature,
			VerifiedKeyRole:                  verifiedKeyRole,
			DurableAdmissionIdentityVerified: true,
			Generation:                       selection.Generation,
			VerifiedPubkey:                   append([]byte(nil), selection.VerificationPubkey...),
			ActivePubkey:                     append([]byte(nil), selection.ActivePubkey...),
			PreviousValidUntil:               selection.PreviousValidUntil,
		}
		// The next key is part of the canonical initial transcript signed by
		// the current key. Only a proof by the authoritative current key may
		// request a generation advance; previous-key rollback admission cannot.
		if bytes.Equal(selection.VerificationPubkey, selection.ActivePubkey) &&
			len(initial.ProviderAdmissionNextPubkey) == ed25519.PublicKeySize &&
			!bytes.Equal(initial.ProviderAdmissionNextPubkey, selection.ActivePubkey) {
			result.RotationPubkey = append([]byte(nil), initial.ProviderAdmissionNextPubkey...)
		}
		return result
	}
	if proofMaterialValid && !selection.Found && !selection.Blocked &&
		connectionAuth.validated && connectionAuth.providerID == initial.ProviderID &&
		len(initial.ProviderAdmissionPubkey) == ed25519.PublicKeySize &&
		ed25519.Verify(ed25519.PublicKey(initial.ProviderAdmissionPubkey), canonical, signature) {
		return identityProofResult{
			Accepted:         true,
			AdmissionMode:    identityAdmissionSignature,
			VerifiedKeyRole:  identityKeyRoleCurrent,
			Generation:       1,
			EnrollmentPubkey: append([]byte(nil), initial.ProviderAdmissionPubkey...),
			ActivePubkey:     append([]byte(nil), initial.ProviderAdmissionPubkey...),
		}
	}
	// Compatibility for pre-enrollment clients. This is deliberately after
	// durable lookup and cannot override an inactive/revoked durable row.
	if proofMaterialValid && !selection.Found && !selection.Blocked {
		if livePubkey, ok := s.currentReceiptPubkey(initial.ProviderID); ok &&
			bytes.Equal(initial.ProviderReceiptPubkey, livePubkey) &&
			ed25519.Verify(ed25519.PublicKey(livePubkey), canonical, signature) {
			return identityProofResult{
				Accepted: true, AdmissionMode: identityAdmissionSignature,
				VerifiedKeyRole: identityKeyRoleCurrent,
				VerifiedPubkey:  append([]byte(nil), livePubkey...),
			}
		}
	}

	// Full local custody loss, degraded previous-key custody, and migration from
	// the dormant App-owned key first prove the exact bearer and proposed key.
	// The dedicated one-shot recovery authorization is consumed only after all
	// remaining admission gates pass, immediately before the durable mutation.
	// Generic signature exemptions are deliberately not recovery authority.
	if proofMaterialValid && initial.ProviderAdmissionRecovery && selection.Found &&
		connectionAuth.validated && connectionAuth.providerID == initial.ProviderID &&
		len(initial.ProviderAdmissionPubkey) == ed25519.PublicKeySize &&
		!bytes.Equal(initial.ProviderAdmissionPubkey, selection.ActivePubkey) &&
		ed25519.Verify(ed25519.PublicKey(initial.ProviderAdmissionPubkey), canonical, signature) &&
		supportsAdmissionIdentityRecovery(s.bootstrapTokens) {
		return identityProofResult{
			Accepted:        true,
			AdmissionMode:   identityAdmissionSignature,
			VerifiedKeyRole: identityKeyRoleRecovery,
			Generation:      selection.Generation,
			ActivePubkey:    append([]byte(nil), selection.ActivePubkey...),
			RecoveryPubkey:  append([]byte(nil), initial.ProviderAdmissionPubkey...),
		}
	}
	// A recovery-marked attempt must never degrade into the generic temporary
	// exemption path. Recovery changes durable authority and therefore requires
	// every recovery precondition above, including proof by the proposed key.
	if initial.ProviderAdmissionRecovery {
		return identityProofResult{}
	}

	// Generic exemptions exist only for the explicit, deadline-bounded bridge.
	// Strict signed rollout metadata makes challenge-bound proof mandatory;
	// dedicated dual-control recovery above remains a separate one-shot path.
	if s.autotuneCatalogBridgeActive() && s.identitySignatures != nil {
		exemptUntil, grantedBy, ok, policyErr := s.identitySignatures.LookupProviderAuthPolicy(ctx, proof.ProviderID)
		if policyErr != nil {
			s.log.Warn().Err(policyErr).Str("provider_id", proof.ProviderID).Msg("identity signature auth-policy lookup failed")
			return identityProofResult{}
		}
		if ok && exemptUntil != nil && exemptUntil.After(s.now()) {
			s.log.Info().
				Str("provider_id", proof.ProviderID).
				Str("granted_by", grantedBy).
				Time("signature_exempt_until", exemptUntil.UTC()).
				Bool("signature_present", proof.IdentitySignature != "").
				Msg("provider_auth_policy_exempt_used")
			return identityProofResult{Accepted: true, AdmissionMode: identityAdmissionExemption}
		}
	}
	return identityProofResult{}
}

func supportsAdmissionIdentityRecovery(store BootstrapTokenStore) bool {
	_, ok := store.(admissionIdentityRotationStore)
	return ok
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

// durableIdentitySignaturePubkey resolves only restart-safe state. blocked is
// true when a durable row exists but is inactive/revoked or when a lookup
// failed; callers must not fall back to self-declared or live-pool identity.
func (s *Server) durableIdentitySignaturePubkey(ctx context.Context, providerID string) (pubkey []byte, found bool, blocked bool) {
	selection := s.durableIdentitySignatureSelection(ctx, AuthRequest{ProviderID: providerID})
	return selection.ActivePubkey, selection.Found, selection.Blocked
}

// durableIdentitySignatureSelection resolves restart-safe admission custody
// and chooses the exact key the challenge asks the provider to prove. The
// authoritative current key wins when offered in either the current or pending
// slot (lost-response recovery); otherwise a still-valid previous key can
// authenticate rolled-back software without gaining rotation authority.
func (s *Server) durableIdentitySignatureSelection(ctx context.Context, initial AuthRequest) durableIdentitySelection {
	if s.bootstrapTokens != nil {
		if rotations, ok := s.bootstrapTokens.(admissionIdentityRotationStore); ok {
			state, found, err := rotations.LookupAdmissionIdentityState(ctx, initial.ProviderID, s.now())
			if err != nil {
				s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("admission identity state lookup failed")
				return durableIdentitySelection{Blocked: true}
			}
			if found {
				if len(state.CurrentPublicKey) != ed25519.PublicKeySize || state.Generation < 1 {
					return durableIdentitySelection{Blocked: true}
				}
				selected := state.CurrentPublicKey
				switch {
				case bytes.Equal(initial.ProviderAdmissionPubkey, state.CurrentPublicKey):
				case bytes.Equal(initial.ProviderAdmissionNextPubkey, state.CurrentPublicKey):
				case len(state.PreviousPublicKey) == ed25519.PublicKeySize &&
					bytes.Equal(initial.ProviderAdmissionPubkey, state.PreviousPublicKey):
					selected = state.PreviousPublicKey
				}
				return durableIdentitySelection{
					VerificationPubkey: append([]byte(nil), selected...),
					ActivePubkey:       append([]byte(nil), state.CurrentPublicKey...),
					Generation:         state.Generation,
					PreviousValidUntil: state.PreviousValidUntil,
					Found:              true,
				}
			}
		}

		identities, supportsAdmissionIdentity := s.bootstrapTokens.(admissionIdentityStore)
		if !supportsAdmissionIdentity {
			goto identitySignatureStore
		}
		pubkey, ok, err := identities.LookupAdmissionIdentityPubkey(ctx, initial.ProviderID)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("admission identity pubkey lookup failed")
			return durableIdentitySelection{Blocked: true}
		}
		if ok {
			if len(pubkey) != ed25519.PublicKeySize {
				return durableIdentitySelection{Blocked: true}
			}
			return durableIdentitySelection{
				VerificationPubkey: append([]byte(nil), pubkey...),
				ActivePubkey:       append([]byte(nil), pubkey...),
				Generation:         1,
				Found:              true,
			}
		}
		exists, err := identities.AdmissionIdentityExists(ctx, initial.ProviderID)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("admission identity existence lookup failed")
			return durableIdentitySelection{Blocked: true}
		}
		if exists {
			return durableIdentitySelection{Blocked: true}
		}
	}
identitySignatureStore:
	if s.identitySignatures != nil {
		pubkey, ok, err := s.identitySignatures.LookupProviderIdentityPubkey(ctx, initial.ProviderID)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("identity pubkey lookup failed")
			return durableIdentitySelection{Blocked: true}
		}
		if ok {
			if len(pubkey) != ed25519.PublicKeySize {
				return durableIdentitySelection{Blocked: true}
			}
			return durableIdentitySelection{
				VerificationPubkey: append([]byte(nil), pubkey...),
				ActivePubkey:       append([]byte(nil), pubkey...),
				Generation:         1,
				Found:              true,
			}
		}
	}
	return durableIdentitySelection{}
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
