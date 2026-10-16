package relayblind

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest"
)

// SPEC-049 §4.13 / SPEC-049-R033 code-bound posture evidence.
const (
	PrivacyCodeBoundVersion = "privacy-code-bound-v1"
	PrivacyCodeBoundDomain  = "macprovider/spec049/code-bound/v1"
	// PrivacyCodeBoundRuntimeIdentifier is the only runtime signing
	// identifier a code-bound statement may name.
	PrivacyCodeBoundRuntimeIdentifier = "live.malibu.provider.cli"
	// MaxPrivacyCodeBoundEvidenceBytes caps one encoded evidence message.
	MaxPrivacyCodeBoundEvidenceBytes = 8192

	privacyCodeBoundEvidenceType = "privacy_code_bound_evidence"
	// codeBoundCheckSkewSeconds is the ±window for checked_at_unix.
	codeBoundCheckSkewSeconds = int64(30)
)

// §4.13 code-signing flag masks.
const (
	// csRequiredFlags is CS_VALID | CS_HARD | CS_KILL | CS_RUNTIME.
	csRequiredFlags uint64 = 0x0001_0301
	// csForbiddenFlags is CS_ADHOC | CS_GET_TASK_ALLOW | CS_INVALID_ALLOWED |
	// CS_DEBUGGED.
	csForbiddenFlags uint64 = 0x1000_0026
)

// Code-bound rejection reasons (SPEC-049-R033). They label one log line and
// one metric; none is buyer-facing and none names a provider or key.
const (
	CodeBoundRejectEvidenceInvalid         = "evidence_invalid"
	CodeBoundRejectBindingMismatch         = "binding_mismatch"
	CodeBoundRejectRuntimeIdentityMismatch = "runtime_identity_mismatch"
	CodeBoundRejectClockSkew               = "clock_skew"
	CodeBoundRejectRecordUnavailable       = "record_unavailable"
	CodeBoundRejectRecordMissing           = "record_missing"
	CodeBoundRejectKeyMismatch             = "key_mismatch"
	CodeBoundRejectAssertionInvalid        = "assertion_invalid"
	CodeBoundRejectCounterNotIncreasing    = "counter_not_increasing"
	CodeBoundRejectStoreUnavailable        = "store_unavailable"
)

// CodeBoundRejectReasons is the closed reason set.
func CodeBoundRejectReasons() []string {
	return []string{
		CodeBoundRejectEvidenceInvalid, CodeBoundRejectBindingMismatch, CodeBoundRejectRuntimeIdentityMismatch,
		CodeBoundRejectClockSkew, CodeBoundRejectRecordUnavailable, CodeBoundRejectRecordMissing,
		CodeBoundRejectKeyMismatch, CodeBoundRejectAssertionInvalid, CodeBoundRejectCounterNotIncreasing,
		CodeBoundRejectStoreUnavailable,
	}
}

// CodeBoundStatement is the closed privacy-code-bound-v1 statement (§4.13).
type CodeBoundStatement struct {
	Version                  string `json:"version"`
	PrivacyClass             string `json:"privacy_class"`
	ProviderID               string `json:"provider_id"`
	AssignedSession          string `json:"assigned_session"`
	Nonce                    string `json:"nonce"`
	PostureDigest            string `json:"posture_digest"`
	SEPublicKey              string `json:"se_public_key"`
	IdentityPublicKey        string `json:"identity_public_key"`
	AppAttestKeyID           string `json:"app_attest_key_id"`
	RuntimeTeamID            string `json:"runtime_team_id"`
	RuntimeSigningIdentifier string `json:"runtime_signing_identifier"`
	RuntimeCDHash            string `json:"runtime_cdhash"`
	RuntimeCSFlags           uint64 `json:"runtime_cs_flags"`
	CheckedAtUnix            int64  `json:"checked_at_unix"`
}

var codeBoundStatementFields = []string{
	"version", "privacy_class", "provider_id", "assigned_session", "nonce", "posture_digest", "se_public_key",
	"identity_public_key", "app_attest_key_id", "runtime_team_id", "runtime_signing_identifier", "runtime_cdhash",
	"runtime_cs_flags", "checked_at_unix",
}

func (s CodeBoundStatement) validate() error {
	if s.Version != PrivacyCodeBoundVersion || s.PrivacyClass != PrivacyClassV1 {
		return fmt.Errorf("%w: code-bound identity", ErrInvalidPrivacy)
	}
	if !visibleASCII(s.ProviderID, MaxIdentifierBytes) || !visibleASCII(s.AssignedSession, MaxIdentifierBytes) {
		return fmt.Errorf("%w: code-bound session", ErrInvalidPrivacy)
	}
	for _, value := range []string{s.Nonce, s.PostureDigest, s.AppAttestKeyID} {
		if _, err := decodeBase64URLFixed(value, 32); err != nil {
			return fmt.Errorf("%w: code-bound digest", ErrInvalidPrivacy)
		}
	}
	if _, err := DecodeSEPublicKey(s.SEPublicKey); err != nil {
		return fmt.Errorf("%w: code-bound secure enclave key", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(s.IdentityPublicKey, ed25519.PublicKeySize); err != nil {
		return fmt.Errorf("%w: code-bound identity key", ErrInvalidPrivacy)
	}
	if !validTeamID(s.RuntimeTeamID) || !visibleASCII(s.RuntimeSigningIdentifier, MaxIdentifierBytes) || !validCDHash(s.RuntimeCDHash) {
		return fmt.Errorf("%w: code-bound runtime identity", ErrInvalidPrivacy)
	}
	if s.RuntimeCSFlags > 0xffff_ffff {
		return fmt.Errorf("%w: code-bound runtime flags", ErrInvalidPrivacy)
	}
	return nil
}

// Framing is the domain followed by every §4.13 field in order: strings as
// u32-framed strings, the nonce, posture digest and key id as their raw 32
// bytes, the flags as u64 and the time as i64.
func (s CodeBoundStatement) Framing() ([]byte, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	nonce, _ := decodeBase64URLFixed(s.Nonce, 32)
	postureDigest, _ := decodeBase64URLFixed(s.PostureDigest, 32)
	keyID, _ := decodeBase64URLFixed(s.AppAttestKeyID, 32)
	var framed bytes.Buffer
	for _, value := range []string{PrivacyCodeBoundDomain, s.Version, s.PrivacyClass, s.ProviderID, s.AssignedSession} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	for _, value := range [][]byte{nonce, postureDigest} {
		if err := writeFrame(&framed, value); err != nil {
			return nil, err
		}
	}
	for _, value := range []string{s.SEPublicKey, s.IdentityPublicKey} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	if err := writeFrame(&framed, keyID); err != nil {
		return nil, err
	}
	for _, value := range []string{s.RuntimeTeamID, s.RuntimeSigningIdentifier, s.RuntimeCDHash} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	writeU64(&framed, s.RuntimeCSFlags)
	writeI64(&framed, s.CheckedAtUnix)
	return framed.Bytes(), nil
}

// ParseCodeBoundStatement decodes the closed statement.
func ParseCodeBoundStatement(raw []byte) (CodeBoundStatement, error) {
	var value CodeBoundStatement
	if err := decodeClosed(raw, &value, codeBoundStatementFields); err != nil {
		return CodeBoundStatement{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.validate(); err != nil {
		return CodeBoundStatement{}, err
	}
	return value, nil
}

// CodeBoundEvidence is one parsed privacy_code_bound_evidence message.
type CodeBoundEvidence struct {
	Statement CodeBoundStatement
	Assertion []byte
}

type codeBoundEvidenceWire struct {
	Type      string          `json:"type"`
	Version   int             `json:"version"`
	Statement json.RawMessage `json:"statement"`
	Assertion string          `json:"assertion"`
}

// ParseCodeBoundEvidence decodes the closed §4.13 message.
func ParseCodeBoundEvidence(raw []byte) (CodeBoundEvidence, error) {
	if len(raw) == 0 || len(raw) > MaxPrivacyCodeBoundEvidenceBytes {
		return CodeBoundEvidence{}, ErrInvalidPrivacy
	}
	var wire codeBoundEvidenceWire
	if err := decodeClosed(raw, &wire, []string{"type", "version", "statement", "assertion"}); err != nil {
		return CodeBoundEvidence{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if wire.Type != privacyCodeBoundEvidenceType || wire.Version != 1 {
		return CodeBoundEvidence{}, ErrInvalidPrivacy
	}
	statement := bytesTrimSpace(wire.Statement)
	if len(statement) == 0 || statement[0] != '{' {
		return CodeBoundEvidence{}, ErrInvalidPrivacy
	}
	parsed, err := ParseCodeBoundStatement(statement)
	if err != nil {
		return CodeBoundEvidence{}, err
	}
	assertion, err := base64.RawURLEncoding.Strict().DecodeString(wire.Assertion)
	if err != nil || len(assertion) == 0 || len(assertion) > appattest.MaxAssertionBytes || encodeBase64URL(assertion) != wire.Assertion {
		return CodeBoundEvidence{}, fmt.Errorf("%w: code-bound assertion", ErrInvalidPrivacy)
	}
	return CodeBoundEvidence{Statement: parsed, Assertion: assertion}, nil
}

// AppAttestKeyLookup reads a provider's SPEC-033 App Attest record: the key
// id and the attested 65-byte uncompressed P-256 public key (nil for a row
// recorded before SPEC-033 v0.9.0). ok is false when the provider has none.
type AppAttestKeyLookup func(ctx context.Context, providerID string) (keyID, publicKey []byte, ok bool, err error)

// CodeBoundConfig wires SPEC-049-R033: the SPEC-033 record reader and the
// App Attest team and bundle the coordinator already pins for SPEC-033.
type CodeBoundConfig struct {
	Lookup   AppAttestKeyLookup
	TeamID   string
	BundleID string
}

type codeBoundVerifier struct {
	lookup AppAttestKeyLookup
	teamID string
	appID  string

	// SPEC-033 records are insert-only and never change, so a complete
	// record is cached for the life of the process; a missing or older
	// row is read again next time. Bounded so it cannot grow without limit.
	mu    sync.Mutex
	cache map[string]recordedAppAttestKey
}

type recordedAppAttestKey struct {
	keyID     []byte
	publicKey []byte
}

// maxCodeBoundRecordCache bounds the per-provider record cache.
const maxCodeBoundRecordCache = 65536

func (v *codeBoundVerifier) record(ctx context.Context, providerID string) (recordedAppAttestKey, bool, error) {
	v.mu.Lock()
	cached, hit := v.cache[providerID]
	v.mu.Unlock()
	if hit {
		return cached, true, nil
	}
	keyID, publicKey, ok, err := v.lookup(ctx, providerID)
	if err != nil || !ok || len(publicKey) == 0 {
		return recordedAppAttestKey{}, ok, err
	}
	record := recordedAppAttestKey{keyID: append([]byte(nil), keyID...), publicKey: append([]byte(nil), publicKey...)}
	v.mu.Lock()
	if len(v.cache) < maxCodeBoundRecordCache {
		v.cache[providerID] = record
	}
	v.mu.Unlock()
	return record, true, nil
}

// PrivacyCodeBoundMetrics is optionally implemented by PrivacyMetrics to
// count code-bound rejections by their closed reason.
type PrivacyCodeBoundMetrics interface {
	IncPrivacyCodeBoundRejection(reason string)
}

// UseCodeBound enables SPEC-049-R033 verification. Without it every posture
// is device-bound. It refuses an incomplete configuration instead of
// verifying against an empty App ID.
func (a *PrivacyAuthority) UseCodeBound(cfg CodeBoundConfig) error {
	if a == nil {
		return ErrStoreUnavailable
	}
	teamID := strings.TrimSpace(cfg.TeamID)
	bundleID := strings.TrimSpace(cfg.BundleID)
	if cfg.Lookup == nil || !validTeamID(teamID) || bundleID == "" {
		return errors.New("relayblind: code-bound privacy needs the App Attest record reader, team id, and bundle id")
	}
	a.codeBound.Store(&codeBoundVerifier{lookup: cfg.Lookup, teamID: teamID, appID: teamID + "." + bundleID, cache: make(map[string]recordedAppAttestKey)})
	return nil
}

// CodeBoundOutcome is the label a verified posture earned and, when evidence
// was present but refused, the closed reason.
type CodeBoundOutcome struct {
	Assurance string
	Reason    string
}

// evaluateCodeBound applies SPEC-049-R033 to evidence held for a posture
// that already passed every device-bound check. It never quarantines and
// never touches eligibility: a failure only withholds the label.
func (a *PrivacyAuthority) evaluateCodeBound(ctx context.Context, providerID, session string, statement PostureStatement, framing []byte, sePin []byte, idPub ed25519.PublicKey, raw []byte, now time.Time) CodeBoundOutcome {
	deviceBound := func(reason string) CodeBoundOutcome {
		if m, ok := a.observer().(PrivacyCodeBoundMetrics); ok && reason != "" {
			m.IncPrivacyCodeBoundRejection(reason)
		}
		return CodeBoundOutcome{Assurance: PrivacyAssurance, Reason: reason}
	}
	if len(raw) == 0 {
		return CodeBoundOutcome{Assurance: PrivacyAssurance}
	}
	verifier := a.codeBound.Load()
	if verifier == nil {
		return deviceBound(CodeBoundRejectRecordUnavailable)
	}
	evidence, err := ParseCodeBoundEvidence(raw)
	if err != nil {
		return deviceBound(CodeBoundRejectEvidenceInvalid)
	}
	cb := evidence.Statement
	postureDigest := sha256.Sum256(framing)
	if cb.ProviderID != providerID || cb.AssignedSession != session || cb.ProviderID != statement.ProviderID ||
		cb.AssignedSession != statement.AssignedSession || cb.Nonce != statement.Nonce ||
		cb.PostureDigest != encodeBase64URL(postureDigest[:]) {
		return deviceBound(CodeBoundRejectBindingMismatch)
	}
	cbSE, errSE := DecodeSEPublicKey(cb.SEPublicKey)
	cbID, errID := decodeBase64URLFixed(cb.IdentityPublicKey, ed25519.PublicKeySize)
	if errSE != nil || errID != nil || subtle.ConstantTimeCompare(cbSE, sePin) != 1 || subtle.ConstantTimeCompare(cbID, idPub) != 1 {
		return deviceBound(CodeBoundRejectBindingMismatch)
	}
	if cb.RuntimeSigningIdentifier != PrivacyCodeBoundRuntimeIdentifier || statement.SigningIdentifier != PrivacyCodeBoundRuntimeIdentifier ||
		cb.RuntimeTeamID != statement.TeamID || cb.RuntimeTeamID != verifier.teamID || cb.RuntimeCDHash != statement.CodeCDHash ||
		cb.RuntimeCSFlags&csRequiredFlags != csRequiredFlags || cb.RuntimeCSFlags&csForbiddenFlags != 0 {
		return deviceBound(CodeBoundRejectRuntimeIdentityMismatch)
	}
	if abs64(now.Unix()-cb.CheckedAtUnix) > codeBoundCheckSkewSeconds {
		return deviceBound(CodeBoundRejectClockSkew)
	}
	record, ok, err := verifier.record(ctx, providerID)
	switch {
	case err != nil:
		return deviceBound(CodeBoundRejectRecordUnavailable)
	case !ok || len(record.publicKey) == 0:
		return deviceBound(CodeBoundRejectRecordMissing)
	}
	keyID, publicKey := record.keyID, record.publicKey
	claimedKeyID, _ := decodeBase64URLFixed(cb.AppAttestKeyID, 32)
	keyDigest := sha256.Sum256(publicKey)
	if subtle.ConstantTimeCompare(keyID, claimedKeyID) != 1 || subtle.ConstantTimeCompare(keyDigest[:], keyID) != 1 {
		return deviceBound(CodeBoundRejectKeyMismatch)
	}
	cbFraming, err := cb.Framing()
	if err != nil {
		return deviceBound(CodeBoundRejectEvidenceInvalid)
	}
	clientDataHash := sha256.Sum256(cbFraming)
	counter, err := appattest.VerifyAssertion(appattest.AssertionInput{
		Assertion:      evidence.Assertion,
		PublicKey:      publicKey,
		ClientDataHash: clientDataHash[:],
		AppID:          verifier.appID,
	})
	if err != nil {
		return deviceBound(CodeBoundRejectAssertionInvalid)
	}
	if counter == 0 {
		return deviceBound(CodeBoundRejectCounterNotIncreasing)
	}
	advanced, err := a.store.AdvanceAppAttestCounter(ctx, cb.AppAttestKeyID, providerID, counter, now)
	switch {
	case err != nil:
		return deviceBound(CodeBoundRejectStoreUnavailable)
	case !advanced:
		return deviceBound(CodeBoundRejectCounterNotIncreasing)
	}
	return CodeBoundOutcome{Assurance: PrivacyAssuranceCodeBound}
}

// AdvanceAppAttestCounter durably records counter as the last App Attest
// assertion counter of keyID (canonical base64url), only when it is strictly
// greater than the stored one and the key belongs to providerID. It reports
// whether exactly one row changed (SPEC-049-R033 item 7).
func (s *Store) AdvanceAppAttestCounter(ctx context.Context, keyID, providerID string, counter uint32, now time.Time) (bool, error) {
	if s == nil || s.db == nil {
		return false, ErrStoreUnavailable
	}
	if counter == 0 || providerID == "" {
		return false, nil
	}
	res, err := s.db.ExecContext(ctx, `
INSERT INTO privacy_app_attest_counters(app_attest_key_id, provider_id, last_counter, updated_at_unix) VALUES(?,?,?,?)
ON CONFLICT(app_attest_key_id) DO UPDATE SET last_counter=excluded.last_counter, updated_at_unix=excluded.updated_at_unix
WHERE privacy_app_attest_counters.last_counter < excluded.last_counter
  AND privacy_app_attest_counters.provider_id = excluded.provider_id`, keyID, providerID, int64(counter), now.Unix())
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%w: %v", ErrStoreUnavailable, err)
	}
	return n == 1, nil
}
