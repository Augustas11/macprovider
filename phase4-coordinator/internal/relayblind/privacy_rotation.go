package relayblind

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// SPEC-049 §4.12 / SPEC-049-R031 in-band identity key rotation.
const (
	PrivacyKeyRotationVersion = "privacy-key-rotation-v1"
	PrivacyKeyRotationDomain  = "macprovider/spec049/key-rotation/v1"
	// MaxPrivacyKeyRotationBytes caps one encoded privacy_key_rotation message.
	MaxPrivacyKeyRotationBytes = 16384

	privacyKeyRotationType = "privacy_key_rotation"
)

// Rotation result reasons (§4.12). They are sent to the provider that asked
// and never name another provider.
const (
	RotationAccepted                = "accepted"
	RotationUnavailable             = "rotation_unavailable"
	RotationInvalid                 = "rotation_invalid"
	RotationIdentityPinned          = "rotation_identity_pinned"
	RotationNotEnrolled             = "rotation_not_enrolled"
	RotationKeyInUse                = "rotation_key_in_use"
	RotationUnapprovedCodeIdentity  = "rotation_unapproved_code_identity"
	RotationStale                   = "rotation_stale"
	RotationQuarantined             = "rotation_quarantined"
	RotationStoreUnavailable        = "rotation_store_unavailable"
	privacyKeyRotationInvalidReason = "privacy_key_rotation_invalid"
	privacyKeyRotationPendingReason = "privacy_key_rotation_pending"
	privacyKeyRotationRejectReason  = "privacy_key_rotation_rejected"
)

// KeyRotationStatement is the closed privacy-key-rotation-v1 statement.
type KeyRotationStatement struct {
	Version                   string `json:"version"`
	PrivacyClass              string `json:"privacy_class"`
	ProviderID                string `json:"provider_id"`
	AssignedSession           string `json:"assigned_session"`
	Nonce                     string `json:"nonce"`
	IssuedAtUnix              int64  `json:"issued_at_unix"`
	PreviousIdentityPublicKey string `json:"previous_identity_public_key"`
	IdentityPublicKey         string `json:"identity_public_key"`
	SEPublicKey               string `json:"se_public_key"`
	PostureDigest             string `json:"posture_digest"`
}

func (s KeyRotationStatement) validate() error {
	if s.Version != PrivacyKeyRotationVersion || s.PrivacyClass != PrivacyClassV1 {
		return fmt.Errorf("%w: rotation identity", ErrInvalidPrivacy)
	}
	if !visibleASCII(s.ProviderID, MaxIdentifierBytes) || !visibleASCII(s.AssignedSession, MaxIdentifierBytes) {
		return fmt.Errorf("%w: rotation session", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(s.Nonce, 32); err != nil {
		return fmt.Errorf("%w: rotation nonce", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(s.PreviousIdentityPublicKey, ed25519.PublicKeySize); err != nil {
		return fmt.Errorf("%w: rotation previous identity", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(s.IdentityPublicKey, ed25519.PublicKeySize); err != nil {
		return fmt.Errorf("%w: rotation identity key", ErrInvalidPrivacy)
	}
	if _, err := DecodeSEPublicKey(s.SEPublicKey); err != nil {
		return fmt.Errorf("%w: rotation secure enclave key", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(s.PostureDigest, sha256.Size); err != nil {
		return fmt.Errorf("%w: rotation posture digest", ErrInvalidPrivacy)
	}
	return nil
}

// Framing is the domain followed by every field in §4.12 order: strings as
// u32-framed strings, the nonce as its raw 32 bytes, the time as i64.
func (s KeyRotationStatement) Framing() ([]byte, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	nonce, err := decodeBase64URLFixed(s.Nonce, 32)
	if err != nil {
		return nil, err
	}
	var framed bytes.Buffer
	for _, value := range []string{PrivacyKeyRotationDomain, s.Version, s.PrivacyClass, s.ProviderID, s.AssignedSession} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	if err := writeFrame(&framed, nonce); err != nil {
		return nil, err
	}
	writeI64(&framed, s.IssuedAtUnix)
	for _, value := range []string{s.PreviousIdentityPublicKey, s.IdentityPublicKey, s.SEPublicKey, s.PostureDigest} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	return framed.Bytes(), nil
}

// ParseKeyRotationStatement decodes the closed statement.
func ParseKeyRotationStatement(raw []byte) (KeyRotationStatement, error) {
	var value KeyRotationStatement
	fields := []string{"version", "privacy_class", "provider_id", "assigned_session", "nonce", "issued_at_unix",
		"previous_identity_public_key", "identity_public_key", "se_public_key", "posture_digest"}
	if err := decodeClosed(raw, &value, fields); err != nil {
		return KeyRotationStatement{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.validate(); err != nil {
		return KeyRotationStatement{}, err
	}
	return value, nil
}

// PostureDigest is canonical base64url SHA-256 of a posture's §4.3 framing.
func PostureDigest(statement PostureStatement) (string, error) {
	framing, err := statement.Framing()
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(framing)
	return encodeBase64URL(digest[:]), nil
}

type privacyRotationWire struct {
	Type                      string          `json:"type"`
	Version                   int             `json:"version"`
	Statement                 json.RawMessage `json:"statement"`
	Posture                   json.RawMessage `json:"posture"`
	SESignature               string          `json:"se_signature"`
	PreviousIdentitySignature string          `json:"previous_identity_signature"`
	IdentitySignature         string          `json:"identity_signature"`
}

func parsePrivacyRotation(raw []byte) (privacyRotationWire, KeyRotationStatement, PostureStatement, error) {
	var wire privacyRotationWire
	if len(raw) == 0 || len(raw) > MaxPrivacyKeyRotationBytes {
		return wire, KeyRotationStatement{}, PostureStatement{}, ErrInvalidPrivacy
	}
	if err := decodeClosed(raw, &wire, []string{"type", "version", "statement", "posture", "se_signature", "previous_identity_signature", "identity_signature"}); err != nil {
		return wire, KeyRotationStatement{}, PostureStatement{}, ErrInvalidPrivacy
	}
	if wire.Type != privacyKeyRotationType || wire.Version != 1 {
		return wire, KeyRotationStatement{}, PostureStatement{}, ErrInvalidPrivacy
	}
	statement, err := ParseKeyRotationStatement(bytesTrimSpace(wire.Statement))
	if err != nil {
		return wire, KeyRotationStatement{}, PostureStatement{}, err
	}
	posture, err := ParsePostureStatement(bytesTrimSpace(wire.Posture))
	if err != nil {
		return wire, KeyRotationStatement{}, PostureStatement{}, err
	}
	return wire, statement, posture, nil
}

// BeginRotationChallenge issues a single-use rotation nonce for a live
// session (SPEC-049-R031 item 1). A refusal returns "" and a §4.12 reason.
func (a *PrivacyAuthority) BeginRotationChallenge(ctx context.Context, providerID, session string, now time.Time) (string, int64, string) {
	if a == nil || a.store == nil || providerID == "" || session == "" {
		return "", 0, RotationUnavailable
	}
	ctx = privacyCtx(ctx)
	id := privacySessionID{providerID: providerID, session: session}
	interval := time.Duration(a.interval) * time.Second
	a.mu.Lock()
	entry := a.ensureLocked(id)
	limited := entry.hasRotationNonce || (!entry.lastRotationChallenge.IsZero() && now.Sub(entry.lastRotationChallenge) < interval)
	if !limited {
		entry.lastRotationChallenge = now
	}
	a.mu.Unlock()
	if limited {
		return "", 0, RotationUnavailable
	}
	if disabled, err := a.store.PrivacyDisabled(ctx); err != nil {
		return "", 0, RotationStoreUnavailable
	} else if disabled {
		return "", 0, RotationUnavailable
	}
	if quarantined, err := a.isQuarantined(ctx, providerID, now); err != nil {
		return "", 0, RotationStoreUnavailable
	} else if quarantined {
		return "", 0, RotationQuarantined
	}
	if _, pinned := a.identity[providerID]; pinned {
		return "", 0, RotationIdentityPinned
	}
	enrollment, enrolled, err := a.store.ActivePrivacyEnrollment(ctx, providerID)
	switch {
	case err != nil:
		return "", 0, RotationStoreUnavailable
	case !enrolled:
		return "", 0, RotationNotEnrolled
	case enrollment.PreviousIdentityFingerprint == "" && now.Unix()-enrollment.EnrolledAtUnix < int64(MinRotationInterval/time.Second):
		// item 11, checked early: a first enrollment cannot be a retry
		// target, so a rotation inside the interval would only be refused.
		return "", 0, RotationUnavailable
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", 0, RotationUnavailable
	}
	nonce := encodeBase64URL(buf)
	a.mu.Lock()
	defer a.mu.Unlock()
	entry = a.ensureLocked(id)
	if entry.hasRotationNonce {
		return "", 0, RotationUnavailable
	}
	entry.rotationNonce = nonce
	entry.rotationIssued = now.Unix()
	entry.hasRotationNonce = true
	// item 2: the sequence accepted when the nonce was issued. A rotation
	// posture at or below it is a regression; one above it that a posture
	// verified meanwhile overtook is only stale.
	entry.rotationSeq, entry.hasRotationSeq = entry.seq, entry.hasSeq
	return nonce, now.Unix(), ""
}

// NoteRotationTimeout drops an unanswered rotation nonce.
func (a *PrivacyAuthority) NoteRotationTimeout(providerID, session string) {
	if a == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if entry := a.sessions[privacySessionID{providerID: providerID, session: session}]; entry != nil {
		entry.hasRotationNonce = false
		entry.rotationNonce = ""
	}
}

func (a *PrivacyAuthority) consumeRotationChallenge(id privacySessionID, nonce string) (postureSnapshot, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil || !entry.hasRotationNonce || nonce == "" || subtle.ConstantTimeCompare([]byte(entry.rotationNonce), []byte(nonce)) != 1 {
		return postureSnapshot{}, false
	}
	snap := postureSnapshot{
		generation: entry.generation, boundGen: entry.boundGen, epoch: entry.epoch,
		seq: entry.rotationSeq, hasSeq: entry.hasRotationSeq, cdhash: entry.cdhash, hasCDHash: entry.hasCDHash,
		attestations: copyAttestations(entry.attestations), issuedAt: entry.rotationIssued,
		currentSeq: entry.seq, hasCurrentSeq: entry.hasSeq,
	}
	entry.hasRotationNonce = false
	entry.rotationNonce = ""
	return snap, true
}

// rotationReject counts a rotation refusal that does not quarantine.
func (a *PrivacyAuthority) rotationReject(reason string) (string, error) {
	if m := a.observer(); m != nil {
		m.IncPrivacyPostureRejection(privacyKeyRotationRejectReason)
	}
	return reason, privacyReject(privacyKeyRotationRejectReason + " " + reason)
}

// rotationQuarantine quarantines for an unsigned or mismatched rotation.
func (a *PrivacyAuthority) rotationQuarantine(ctx context.Context, providerID string, now time.Time, reason string) (string, error) {
	return RotationInvalid, a.failQuarantine(ctx, providerID, now, reason)
}

// VerifyRotation is SPEC-049-R031 items 2 to 6. nonce is the outstanding
// rotation nonce the coordinator issued to this session. It returns the
// §4.12 result reason ("accepted" on success) and, on refusal, an error.
// The caller holds the provider section, so session replacement cannot
// interleave.
func (a *PrivacyAuthority) VerifyRotation(ctx context.Context, providerID, session, nonce string, raw []byte, sessionSEKey []byte, now time.Time) (string, error) {
	if a == nil || a.store == nil {
		return RotationUnavailable, ErrStoreUnavailable
	}
	ctx = privacyCtx(ctx)
	id := privacySessionID{providerID: providerID, session: session}
	snap, ok := a.consumeRotationChallenge(id, nonce)
	if !ok {
		return a.rotationReject(RotationStale)
	}
	wire, statement, posture, err := parsePrivacyRotation(raw)
	if err != nil {
		return a.rotationReject(RotationInvalid)
	}
	if a.late(now.Unix(), snap.issuedAt) || abs64(now.Unix()-statement.IssuedAtUnix) > privacyClockSkewSeconds || abs64(now.Unix()-posture.IssuedAtUnix) > privacyClockSkewSeconds {
		return a.rotationReject(RotationStale)
	}
	if statement.Nonce != nonce || posture.Nonce != nonce || statement.ProviderID != providerID || statement.AssignedSession != session ||
		posture.ProviderID != providerID || posture.AssignedSession != session {
		return a.rotationReject(RotationInvalid)
	}
	digest, err := PostureDigest(posture)
	if err != nil || subtle.ConstantTimeCompare([]byte(digest), []byte(statement.PostureDigest)) != 1 {
		return a.rotationReject(RotationInvalid)
	}
	if _, pinned := a.identity[providerID]; pinned {
		return a.rotationReject(RotationIdentityPinned)
	}
	enrollment, enrolled, err := a.store.ActivePrivacyEnrollment(ctx, providerID)
	if err != nil {
		return a.rotationReject(RotationStoreUnavailable)
	}
	if !enrolled {
		return a.rotationReject(RotationNotEnrolled)
	}
	sePin := a.sePins[providerID]
	if sePin == nil {
		if sePin, err = DecodeSEPublicKey(enrollment.SEPublicKey); err != nil {
			return a.rotationReject(RotationStoreUnavailable)
		}
	}
	previous, _ := decodeBase64URLFixed(statement.PreviousIdentityPublicKey, ed25519.PublicKeySize)
	next, _ := decodeBase64URLFixed(statement.IdentityPublicKey, ed25519.PublicKeySize)
	previousFingerprint := PublicKeyFingerprint(previous)
	// item 6: a retry of the rotation that produced the active enrollment.
	retry := enrollment.IdentityPublicKey == statement.IdentityPublicKey && enrollment.PreviousIdentityFingerprint != "" &&
		enrollment.PreviousIdentityFingerprint == previousFingerprint
	if statement.SEPublicKey != base64.StdEncoding.EncodeToString(sePin) || (!retry && statement.PreviousIdentityPublicKey != enrollment.IdentityPublicKey) {
		return a.rotationQuarantine(ctx, providerID, now, privacyKeyRotationInvalidReason)
	}
	if bytes.Equal(previous, next) {
		return a.rotationReject(RotationInvalid)
	}
	framing, err := statement.Framing()
	if err != nil {
		return a.rotationReject(RotationInvalid)
	}
	if !verifySEPosture(sePin, framing, wire.SESignature) ||
		!verifyIdentityPosture(ed25519.PublicKey(previous), framing, wire.PreviousIdentitySignature) ||
		!verifyIdentityPosture(ed25519.PublicKey(next), framing, wire.IdentitySignature) {
		return a.rotationQuarantine(ctx, providerID, now, privacyKeyRotationInvalidReason)
	}
	if reason, quarantine := a.policyFailure(posture, snap, sessionSEKey, sePin, now); reason != "" {
		if quarantine {
			return a.rotationQuarantine(ctx, providerID, now, reason)
		}
		return a.rotationReject(RotationUnapprovedCodeIdentity)
	}
	if snap.hasCurrentSeq && posture.Sequence <= snap.currentSeq {
		// A posture verified after the nonce was issued overtook this one.
		return a.rotationReject(RotationStale)
	}
	if !a.backendAllowed(posture.SEKeyBackend) {
		return a.rotationReject(RotationInvalid)
	}
	if disabled, err := a.store.PrivacyDisabled(ctx); err != nil {
		return a.rotationReject(RotationStoreUnavailable)
	} else if disabled {
		return a.rotationReject(RotationUnavailable)
	}
	if quarantined, err := a.isQuarantined(ctx, providerID, now); err != nil {
		return a.rotationReject(RotationStoreUnavailable)
	} else if quarantined {
		return a.rotationReject(RotationQuarantined)
	}
	if !a.postureStillCurrent(id, snap) {
		return a.rotationReject(RotationStale)
	}
	if !retry {
		err = a.store.RotatePrivacyIdentity(ctx, enrollment, PrivacyEnrollment{
			ProviderID:          providerID,
			IdentityPublicKey:   statement.IdentityPublicKey,
			IdentityFingerprint: PublicKeyFingerprint(next),
			SEPublicKey:         enrollment.SEPublicKey,
			SEFingerprint:       enrollment.SEFingerprint,
			TeamID:              posture.TeamID,
			SigningIdentifier:   posture.SigningIdentifier,
			CodeCDHash:          posture.CodeCDHash,
			BinaryVersion:       posture.BinaryVersion,
		}, now, a.replayRetention)
		switch {
		case errors.Is(err, ErrEnrollmentKeyChanged):
			return a.rotationReject(RotationStale)
		case errors.Is(err, ErrEnrollmentKeyReused):
			return a.rotationReject(RotationKeyInUse)
		case errors.Is(err, ErrRotationTooSoon):
			return a.rotationReject(RotationUnavailable)
		case errors.Is(err, ErrPrivacyQuarantined):
			return a.rotationReject(RotationQuarantined)
		case err != nil:
			return a.rotationReject(RotationStoreUnavailable)
		}
	}
	a.commitRotation(id, posture, ed25519.PublicKey(previous))
	return RotationAccepted, nil
}

// commitRotation clears every session's posture eligibility for the
// provider, drops this session's outstanding posture nonce so a posture
// signed with the retired key cannot land, and records the posture sequence
// and the retired identity key for this session.
func (a *PrivacyAuthority) commitRotation(id privacySessionID, posture PostureStatement, retired ed25519.PublicKey) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.epochs[id.providerID]++
	epoch := a.epochs[id.providerID]
	for sid, entry := range a.sessions {
		if sid.providerID != id.providerID {
			continue
		}
		entry.epoch = epoch
		entry.generation = a.nextGenerationLocked()
		entry.verified = false
		entry.digests = nil
		entry.attestations = nil
		entry.claim = nil
		entry.hasNonce = false
		entry.nonce = ""
	}
	entry := a.ensureLocked(id)
	entry.seq = posture.Sequence
	entry.hasSeq = true
	entry.cdhash = posture.CodeCDHash
	entry.hasCDHash = true
	entry.retiredIdentity = append(ed25519.PublicKey(nil), retired...)
}
