package trustpool

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/providerid"
)

const (
	ProviderPoolDelegationSchemaVersion           = "provider-pool-delegation-v1"
	ProviderPoolDelegationRevocationSchemaVersion = "provider-pool-delegation-revocation-v1"
	ProviderPoolDelegationRevocationSemantics     = "owner_revocable"

	providerPoolDelegationSignatureTag           = "macprovider/spec043/provider-pool-delegation-sig/v1"
	providerPoolDelegationRevocationSignatureTag = "macprovider/spec043/provider-pool-delegation-revocation-sig/v1"
)

var (
	ErrProviderDelegation  = errors.New("trustpool: provider pool delegation invalid")
	errDelegationSignature = errors.New("trustpool: provider pool delegation signature verification failed")
)

type delegationLedgerKey struct {
	PoolID       string
	DelegationID string
}

type poolProviderKey struct {
	PoolID     string
	ProviderID string
}

type delegationRecord struct {
	PoolID                  string
	CreatorAccountID        string
	ProviderID              string
	DelegationID            string
	DelegationOperationID   string
	ManifestCoreDigest      string
	EnvironmentNetworkID    string
	CoordinatorAudience     string
	ProviderOwnerKeyID      string
	ProviderOwnerKeyVersion string
	ProviderOwnerPublicKey  []byte
	IssuedAt                time.Time
	ExpiresAt               time.Time
	Revoked                 bool
}

func CoordinatorAudienceForEnvironment(environment string) string {
	environment = strings.TrimSpace(environment)
	if environment == "" {
		return ""
	}
	return "macprovider/spec043/coordinator-audience/v1/" + environment
}

func ProviderPoolDelegationSigningMessage(fields map[string]any) ([]byte, error) {
	return taggedCanonicalJSON(providerPoolDelegationSignatureTag, fields)
}

func ProviderPoolDelegationRevocationSigningMessage(fields map[string]any) ([]byte, error) {
	return taggedCanonicalJSON(providerPoolDelegationRevocationSignatureTag, fields)
}

func delegationSignedFieldsFromEvent(e DurableEvent) (map[string]any, error) {
	if err := requireLowerHex64(e.ManifestCoreDigest); err != nil {
		return nil, ErrProviderDelegation
	}
	pub, err := canonicalBase64(e.ProviderOwnerPublicKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, ErrProviderDelegation
	}
	return map[string]any{
		"schema_version":             ProviderPoolDelegationSchemaVersion,
		"creator_account_id":         e.CreatorAccountID,
		"pool_id":                    e.PoolID,
		"provider_identity":          e.ProviderID,
		"delegation_id":              e.DelegationID,
		"operation_id":               e.DelegationOperationID,
		"manifest_core_digest":       e.ManifestCoreDigest,
		"environment_network_id":     e.EnvironmentNetworkID,
		"coordinator_audience":       e.CoordinatorAudience,
		"provider_owner_key_id":      e.ProviderOwnerKeyID,
		"provider_owner_key_version": e.ProviderOwnerKeyVersion,
		"provider_owner_public_key":  e.ProviderOwnerPublicKey,
		"issued_at":                  e.DelegationIssuedAt,
		"expires_at":                 e.DelegationExpiresAt,
		"revocation_semantics":       ProviderPoolDelegationRevocationSemantics,
	}, nil
}

func delegationRevocationSignedFieldsFromEvent(e DurableEvent, rec delegationRecord) (map[string]any, error) {
	if err := requireLowerHex64(e.ManifestCoreDigest); err != nil {
		return nil, ErrProviderDelegation
	}
	return map[string]any{
		"schema_version":             ProviderPoolDelegationRevocationSchemaVersion,
		"creator_account_id":         e.CreatorAccountID,
		"pool_id":                    e.PoolID,
		"provider_identity":          e.ProviderID,
		"delegation_id":              e.DelegationID,
		"operation_id":               e.DelegationOperationID,
		"manifest_core_digest":       e.ManifestCoreDigest,
		"environment_network_id":     e.EnvironmentNetworkID,
		"coordinator_audience":       e.CoordinatorAudience,
		"provider_owner_key_id":      e.ProviderOwnerKeyID,
		"provider_owner_key_version": e.ProviderOwnerKeyVersion,
		"revoked_at":                 e.DelegationRevokedAt,
		"revocation_semantics":       ProviderPoolDelegationRevocationSemantics,
	}, nil
}

func verifyProviderOwnerEd25519Signature(publicKey, signature []byte, msg []byte) error {
	if len(publicKey) != ed25519.PublicKeySize || len(signature) == 0 {
		return errDelegationSignature
	}
	if !ed25519.Verify(ed25519.PublicKey(publicKey), msg, signature) {
		return errDelegationSignature
	}
	return nil
}

func parseDelegationTimestamp(value string) (time.Time, error) {
	ts, err := time.Parse(time.RFC3339, strings.TrimSpace(value))
	if err != nil {
		return time.Time{}, ErrProviderDelegation
	}
	return ts.UTC(), nil
}

func validateDelegationGrantEvent(e DurableEvent, p *ReconstructedPoolState, at time.Time) (delegationRecord, error) {
	var zero delegationRecord
	if p == nil || p.RootIssuer == nil || p.ManifestVersion == 0 {
		return zero, ErrProviderDelegation
	}
	if e.EventType != EventDelegationGranted {
		return zero, ErrProviderDelegation
	}
	if e.CreatorAccountID == "" || e.PoolID == "" || e.ProviderID == "" || e.DelegationID == "" ||
		e.DelegationOperationID == "" || e.ProviderOwnerKeyID == "" || e.ProviderOwnerKeyVersion == "" ||
		e.ProviderOwnerPublicKey == "" || e.DelegationIssuedAt == "" || e.DelegationExpiresAt == "" ||
		e.EnvironmentNetworkID == "" || e.CoordinatorAudience == "" || e.ProviderPoolDelegationSignature == "" {
		return zero, ErrProviderDelegation
	}
	if err := providerid.Validate(e.ProviderID); err != nil {
		return zero, ErrProviderDelegation
	}
	if e.CreatorAccountID != p.CreatorAccountID {
		return zero, ErrProviderDelegation
	}
	if e.ManifestCoreDigest != p.ManifestCoreDigest {
		return zero, ErrProviderDelegation
	}
	expectedAudience := CoordinatorAudienceForEnvironment(p.RootIssuer.LaunchEnvironment)
	if e.CoordinatorAudience != expectedAudience || e.EnvironmentNetworkID != p.RootIssuer.LaunchEnvironment {
		return zero, ErrProviderDelegation
	}
	issuedAt, err := parseDelegationTimestamp(e.DelegationIssuedAt)
	if err != nil {
		return zero, err
	}
	expiresAt, err := parseDelegationTimestamp(e.DelegationExpiresAt)
	if err != nil || !expiresAt.After(issuedAt) {
		return zero, ErrProviderDelegation
	}
	if !at.Before(expiresAt) {
		return zero, ErrProviderDelegation
	}
	fields, err := delegationSignedFieldsFromEvent(e)
	if err != nil {
		return zero, err
	}
	msg, err := ProviderPoolDelegationSigningMessage(fields)
	if err != nil {
		return zero, ErrProviderDelegation
	}
	pub, err := canonicalBase64(e.ProviderOwnerPublicKey)
	if err != nil {
		return zero, ErrProviderDelegation
	}
	sig, err := canonicalBase64(e.ProviderPoolDelegationSignature)
	if err != nil {
		return zero, ErrProviderDelegation
	}
	if err := verifyProviderOwnerEd25519Signature(pub, sig, msg); err != nil {
		return zero, ErrProviderDelegation
	}
	return delegationRecord{
		PoolID:                  e.PoolID,
		CreatorAccountID:        e.CreatorAccountID,
		ProviderID:              e.ProviderID,
		DelegationID:            e.DelegationID,
		DelegationOperationID:   e.DelegationOperationID,
		ManifestCoreDigest:      e.ManifestCoreDigest,
		EnvironmentNetworkID:    e.EnvironmentNetworkID,
		CoordinatorAudience:     e.CoordinatorAudience,
		ProviderOwnerKeyID:      e.ProviderOwnerKeyID,
		ProviderOwnerKeyVersion: e.ProviderOwnerKeyVersion,
		ProviderOwnerPublicKey:  append([]byte(nil), pub...),
		IssuedAt:                issuedAt,
		ExpiresAt:               expiresAt,
	}, nil
}

func validateDelegationRevocationEvent(e DurableEvent, rec delegationRecord, at time.Time) error {
	if e.EventType != EventDelegationRevoked {
		return ErrProviderDelegation
	}
	if e.CreatorAccountID == "" || e.PoolID == "" || e.ProviderID == "" || e.DelegationID == "" ||
		e.DelegationOperationID == "" || e.ProviderOwnerKeyID == "" || e.ProviderOwnerKeyVersion == "" ||
		e.DelegationRevokedAt == "" || e.EnvironmentNetworkID == "" || e.CoordinatorAudience == "" ||
		e.ProviderPoolDelegationRevocationSignature == "" {
		return ErrProviderDelegation
	}
	if rec.Revoked || rec.PoolID == "" {
		return ErrProviderDelegation
	}
	if e.CreatorAccountID != rec.CreatorAccountID || e.PoolID != rec.PoolID || e.ProviderID != rec.ProviderID ||
		e.DelegationID != rec.DelegationID || e.ProviderOwnerKeyID != rec.ProviderOwnerKeyID ||
		e.ProviderOwnerKeyVersion != rec.ProviderOwnerKeyVersion {
		return ErrProviderDelegation
	}
	if e.ManifestCoreDigest != rec.ManifestCoreDigest {
		return ErrProviderDelegation
	}
	if e.CoordinatorAudience != rec.CoordinatorAudience || e.EnvironmentNetworkID != rec.EnvironmentNetworkID {
		return ErrProviderDelegation
	}
	revokedAt, err := parseDelegationTimestamp(e.DelegationRevokedAt)
	if err != nil || revokedAt.Before(rec.IssuedAt) {
		return ErrProviderDelegation
	}
	fields, err := delegationRevocationSignedFieldsFromEvent(e, rec)
	if err != nil {
		return err
	}
	msg, err := ProviderPoolDelegationRevocationSigningMessage(fields)
	if err != nil {
		return ErrProviderDelegation
	}
	sig, err := canonicalBase64(e.ProviderPoolDelegationRevocationSignature)
	if err != nil {
		return ErrProviderDelegation
	}
	return verifyProviderOwnerEd25519Signature(rec.ProviderOwnerPublicKey, sig, msg)
}

func (s *ReconstructedState) ensureDelegationMaps() {
	if s == nil {
		return
	}
	if s.delegations == nil {
		s.delegations = make(map[delegationLedgerKey]delegationRecord)
	}
	if s.consumedDelegationOperationIDs == nil {
		s.consumedDelegationOperationIDs = make(map[string]struct{})
	}
	if s.activeProviderDelegations == nil {
		s.activeProviderDelegations = make(map[poolProviderKey]string)
	}
}

func (s *ReconstructedState) delegationRecordFor(poolID, delegationID string) (delegationRecord, bool) {
	s.ensureDelegationMaps()
	rec, ok := s.delegations[delegationLedgerKey{PoolID: poolID, DelegationID: delegationID}]
	return rec, ok
}

func (s *ReconstructedState) delegationEligible(p *ReconstructedPoolState, providerID string, at time.Time) bool {
	if p == nil || s == nil {
		return false
	}
	delegationID, bound := p.MemberDelegationIDs[providerID]
	if !bound || delegationID == "" {
		return true
	}
	activeID, ok := s.activeProviderDelegations[poolProviderKey{PoolID: p.PoolID, ProviderID: providerID}]
	if !ok || activeID != delegationID {
		return false
	}
	rec, ok := s.delegationRecordFor(p.PoolID, delegationID)
	if !ok || rec.Revoked {
		return false
	}
	if !at.Before(rec.ExpiresAt) {
		return false
	}
	if rec.ManifestCoreDigest != p.ManifestCoreDigest {
		return false
	}
	return true
}

func SignProviderPoolDelegation(privateKey ed25519.PrivateKey, signed map[string]any) (string, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return "", fmt.Errorf("trustpool: invalid provider owner private key")
	}
	msg, err := ProviderPoolDelegationSigningMessage(signed)
	if err != nil {
		return "", err
	}
	sig := ed25519.Sign(privateKey, msg)
	return base64.StdEncoding.EncodeToString(sig), nil
}

func SignProviderPoolDelegationRevocation(privateKey ed25519.PrivateKey, signed map[string]any) (string, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return "", fmt.Errorf("trustpool: invalid provider owner private key")
	}
	msg, err := ProviderPoolDelegationRevocationSigningMessage(signed)
	if err != nil {
		return "", err
	}
	sig := ed25519.Sign(privateKey, msg)
	return base64.StdEncoding.EncodeToString(sig), nil
}

func providerOwnerPublicKeyBase64(publicKey ed25519.PublicKey) string {
	return base64.StdEncoding.EncodeToString(publicKey)
}

func providerDelegationManifestDigestHex(digest []byte) string {
	return hex.EncodeToString(digest)
}

// ParseProviderOwnerPublicKeys decodes configured provider_id -> base64 Ed25519
// public keys for SPEC-003 owner binding on ProviderPoolDelegationV1 events.
func ParseProviderOwnerPublicKeys(raw map[string]string) (map[string][]byte, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	out := make(map[string][]byte, len(raw))
	for providerID, encoded := range raw {
		providerID = strings.TrimSpace(providerID)
		if providerID == "" {
			return nil, fmt.Errorf("trustpool: provider owner public keys contain empty provider id")
		}
		pub, err := canonicalBase64(strings.TrimSpace(encoded))
		if err != nil || len(pub) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("trustpool: invalid provider owner public key for %q", providerID)
		}
		out[providerID] = append([]byte(nil), pub...)
	}
	return out, nil
}

// ProviderOwnerPublicKeyLookup returns an AdminDeps resolver backed by parsed keys.
func ProviderOwnerPublicKeyLookup(keys map[string][]byte) func(providerID string) ([]byte, bool) {
	if len(keys) == 0 {
		return nil
	}
	return func(providerID string) ([]byte, bool) {
		key, ok := keys[providerID]
		if !ok || len(key) != ed25519.PublicKeySize {
			return nil, false
		}
		return append([]byte(nil), key...), true
	}
}
