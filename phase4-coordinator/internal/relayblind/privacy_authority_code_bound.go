package relayblind

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest"
)

// SPEC-049-R027 enrollment result statuses.
const (
	AppAttestEnrolled         = "enrolled"
	AppAttestReenrollRequired = "reenroll_required"
	AppAttestUnavailable      = "unavailable"
	AppAttestRejected         = "rejected"

	appAttestEnrollWindowSeconds = int64(60)
)

// AppAttestNotifier delivers an unsolicited privacy_app_attest_enroll_result
// to a live session (SPEC-049-R033). keyID is canonical base64url.
type AppAttestNotifier func(providerID, session, keyID, status string)

// SetAppAttestNotifier wires the unsolicited reenroll_required sender.
func (a *PrivacyAuthority) SetAppAttestNotifier(notify AppAttestNotifier) {
	if a == nil {
		return
	}
	a.notifyMu.Lock()
	a.notify = notify
	a.notifyMu.Unlock()
}

// CodeBoundActive reports whether code-bound can be granted at all: it is
// enabled, a team is configured, and the compiled Apple root passed its
// fingerprint check. Every other path fails closed (SPEC-049-R033).
func (a *PrivacyAuthority) CodeBoundActive() bool {
	return a != nil && a.codeBound && a.teamID != "" && a.appAttestRoot != nil
}

// AppAttestReply is the coordinator answer to an enrollment request. A
// non-empty Challenge means a privacy_app_attest_enroll_challenge is sent;
// otherwise Status is sent as privacy_app_attest_enroll_result.
type AppAttestReply struct {
	Status       string
	Challenge    string
	IssuedAtUnix int64
}

// BeginEnrollment answers privacy_app_attest_enroll_request per
// SPEC-049-R027.
func (a *PrivacyAuthority) BeginEnrollment(ctx context.Context, providerID, session, keyIDB64 string, now time.Time) AppAttestReply {
	unavailable := AppAttestReply{Status: AppAttestUnavailable}
	if !a.CodeBoundActive() || a.store == nil || providerID == "" || session == "" {
		return unavailable
	}
	ctx = privacyCtx(ctx)
	keyID, err := decodeBase64URLFixed(keyIDB64, 32)
	if err != nil {
		return unavailable
	}
	id := privacySessionID{providerID: providerID, session: session}
	a.mu.Lock()
	entry := a.sessions[id]
	ready := entry != nil && len(entry.attestations) > 0
	if ready && entry.enroll.active && now.Unix()-entry.enroll.issued > appAttestEnrollWindowSeconds {
		entry.enroll = pendingEnrollment{}
	}
	outstanding := ready && entry.enroll.active
	a.mu.Unlock()
	if !ready || outstanding {
		return unavailable
	}
	quarantined, err := a.store.IsQuarantined(ctx, providerID, now)
	if err != nil || quarantined {
		return unavailable
	}
	key, found, err := a.store.AppAttestKeyByID(ctx, keyID)
	if err != nil {
		return unavailable
	}
	if found {
		if key.ProviderID != providerID {
			_ = a.failQuarantine(ctx, providerID, now, ReasonAppAttestBindingMismatch)
			return AppAttestReply{Status: AppAttestRejected}
		}
		if key.State != AppAttestKeyActive {
			return AppAttestReply{Status: AppAttestReenrollRequired}
		}
		if !a.bindingCurrent(key, providerID) {
			if _, err := a.store.RevokeAppAttestKey(ctx, providerID, keyID, ReasonBindingStale, now); err != nil {
				return unavailable
			}
			return AppAttestReply{Status: AppAttestReenrollRequired}
		}
		if !a.setEnrolled(id, keyID) {
			return unavailable
		}
		return AppAttestReply{Status: AppAttestEnrolled}
	}
	allowed, err := a.store.RecordAppAttestChallenge(ctx, providerID, now, a.maxEnrollments)
	if err != nil || !allowed {
		return unavailable
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return unavailable
	}
	challenge := base64.RawURLEncoding.EncodeToString(buf)
	a.mu.Lock()
	defer a.mu.Unlock()
	entry = a.sessions[id]
	if entry == nil || entry.enroll.active {
		return unavailable
	}
	entry.enroll = pendingEnrollment{active: true, challenge: challenge, keyID: keyID, issued: now.Unix()}
	return AppAttestReply{Challenge: challenge, IssuedAtUnix: now.Unix()}
}

// CompleteEnrollment verifies privacy_app_attest_enrollment per
// SPEC-049-R027..R029 and returns the status to send.
func (a *PrivacyAuthority) CompleteEnrollment(ctx context.Context, providerID, session string, raw []byte, now time.Time) string {
	if a == nil || a.store == nil {
		return AppAttestUnavailable
	}
	ctx = privacyCtx(ctx)
	id := privacySessionID{providerID: providerID, session: session}
	pending := a.takeEnrollment(id)
	if !a.CodeBoundActive() || !pending.active {
		return AppAttestUnavailable
	}
	elapsed := now.Unix() - pending.issued
	if elapsed < 0 || elapsed > appAttestEnrollWindowSeconds {
		return AppAttestUnavailable
	}
	reject := func(reason string) string {
		_ = a.failQuarantine(ctx, providerID, now, reason)
		return AppAttestRejected
	}
	wire, err := parsePrivacyAppAttestEnrollment(raw)
	if err != nil {
		return reject(ReasonAppAttestBindingMismatch)
	}
	statement, err := ParseAppAttestEnrollmentStatement(wire.Statement)
	if err != nil {
		return reject(ReasonAppAttestBindingMismatch)
	}
	// A late or non-echoed enrollment is discarded without quarantine.
	if abs64(now.Unix()-statement.IssuedAtUnix) > privacyClockSkewSeconds || statement.Challenge != pending.challenge {
		return AppAttestUnavailable
	}
	sePin, hasSE := a.sePins[providerID]
	idPub, hasID := a.identity[providerID]
	if !hasSE || !hasID {
		return AppAttestUnavailable
	}
	framing, err := statement.Framing()
	if err != nil {
		return reject(ReasonAppAttestBindingMismatch)
	}
	// SPEC-049-R028 step 1.
	if !verifySEPosture(sePin, framing, wire.SESignature) || !verifyIdentityPosture(idPub, framing, wire.IdentitySignature) ||
		statement.ProviderID != providerID || statement.AssignedSession != session ||
		statement.AppAttestKeyID != base64.RawURLEncoding.EncodeToString(pending.keyID) ||
		statement.TeamID != a.teamID || statement.BundleID != PrivacySupervisorBundleID ||
		statement.Environment != PrivacyAppAttestEnvironment ||
		statement.SEPublicKey != base64.RawURLEncoding.EncodeToString(sePin) ||
		statement.IdentityPublicKey != base64.RawURLEncoding.EncodeToString(idPub) {
		return reject(ReasonAppAttestBindingMismatch)
	}
	// Steps 2..8.
	attestation, err := decodeBase64URL(wire.Attestation)
	if err != nil || len(attestation) > appattest.MaxAttestationBytes {
		return reject(ReasonAppAttestAttestationInvalid)
	}
	attested, err := appattest.VerifyAttestation(appattest.AttestationInput{
		Attestation: attestation, KeyID: pending.keyID, ClientDataHash: sha256Bytes(framing),
		AppID: PrivacyAppID(a.teamID), Now: now, Root: a.appAttestRoot,
	})
	if errors.Is(err, appattest.ErrACLMismatch) {
		return reject(ReasonAppAttestACLMismatch)
	}
	if err != nil {
		return reject(ReasonAppAttestAttestationInvalid)
	}
	// Step 9.
	if !a.childApproved(statement.ChildCDHash, now) || !PrivacyChildCSFlagsOK(statement.ChildCSFlags) {
		return reject(ReasonSupervisorChildCheckFailed)
	}
	existing, found, err := a.store.AppAttestKeyByID(ctx, pending.keyID)
	if err != nil {
		return AppAttestUnavailable
	}
	if found {
		if existing.ProviderID != providerID {
			return reject(ReasonAppAttestBindingMismatch)
		}
		return AppAttestUnavailable
	}
	err = a.store.EnrollAppAttestKey(ctx, AppAttestKey{
		KeyID: pending.keyID, ProviderID: providerID, PublicKey: attested.PublicKey, TeamID: a.teamID,
		SEPublicKeySHA256: sha256Bytes(sePin), IdentityPublicKeySHA256: sha256Bytes(idPub),
	}, now)
	if err != nil {
		return AppAttestUnavailable
	}
	if !a.setEnrolled(id, pending.keyID) {
		return AppAttestUnavailable
	}
	return AppAttestEnrolled
}

// verifyPostureV2 is SPEC-049-R030 and SPEC-049-R031 for a version 2
// posture response.
func (a *PrivacyAuthority) verifyPostureV2(ctx context.Context, providerID, session, nonce string, raw []byte, sessionSEKey []byte, now time.Time) error {
	response, err := parsePrivacyPostureV2Response(raw)
	if err != nil {
		return privacyReject("posture_closed")
	}
	statement, err := ParsePostureStatementV2(response.Statement)
	if err != nil {
		return privacyReject("posture_closed")
	}
	id := privacySessionID{providerID: providerID, session: session}
	snap, ok := a.consumeChallenge(id, nonce, statement.Nonce)
	if !ok {
		return privacyReject("posture_nonce_mismatch")
	}
	if !snap.enrolled || !a.CodeBoundActive() {
		a.NoteChallengeTimeout(providerID, session)
		return privacyReject("posture_v2_not_enrolled")
	}
	framing, err := statement.Framing()
	if err != nil {
		return privacyReject("posture_closed")
	}
	sePin, hasSE := a.sePins[providerID]
	idPub, hasID := a.identity[providerID]
	if !hasSE || !hasID {
		return privacyReject("posture_pin_missing")
	}
	if !verifySEPosture(sePin, framing, response.SESignature) || !verifyIdentityPosture(idPub, framing, response.IdentitySignature) {
		return a.failQuarantine(ctx, providerID, now, "posture_signature_failure")
	}
	if statement.ProviderID != providerID || statement.AssignedSession != session {
		return privacyReject("posture_session_binding")
	}
	if reason := a.policyFailure(statement.PostureStatement, snap, sessionSEKey, sePin, now, PrivacyAssuranceCodeBound); reason != "" {
		return a.failQuarantine(ctx, providerID, now, reason)
	}
	keyID, _ := decodeBase64URLFixed(statement.AppAttestKeyID, 32)
	if statement.Assurance != PrivacyAssuranceCodeBound || subtle.ConstantTimeCompare(keyID, snap.enrolledKey) != 1 ||
		statement.SupervisorTeamID != a.teamID || statement.TeamID != a.teamID || statement.SupervisorBundleID != PrivacySupervisorBundleID {
		a.NoteChallengeTimeout(providerID, session)
		return privacyReject("posture_code_bound_binding")
	}
	if statement.childCheckFailure() {
		return a.failQuarantine(ctx, providerID, now, ReasonSupervisorChildCheckFailed)
	}
	if err := a.postureLiveness(ctx, providerID, session, statement.PostureStatement, snap, now); err != nil {
		return err
	}
	// SPEC-049-R029: the key must still be the provider's active key bound
	// to the current pins and team.
	key, found, err := a.store.AppAttestKeyByID(ctx, keyID)
	if err != nil {
		a.NoteChallengeTimeout(providerID, session)
		return err
	}
	if !found || key.ProviderID != providerID || key.State != AppAttestKeyActive {
		a.endEnrollment(id, keyID)
		return privacyReject("posture_app_attest_key_inactive")
	}
	if !a.bindingCurrent(key, providerID) {
		if _, err := a.store.RevokeAppAttestKey(ctx, providerID, keyID, ReasonBindingStale, now); err != nil {
			a.NoteChallengeTimeout(providerID, session)
			return err
		}
		a.endEnrollment(id, keyID)
		return privacyReject(ReasonBindingStale)
	}
	// SPEC-049-R031.
	assertion, err := decodeBase64URL(response.AppAttestAssertion)
	if err != nil {
		return a.failQuarantine(ctx, providerID, now, ReasonAppAttestAssertionInvalid)
	}
	counter, err := appattest.VerifyAssertion(appattest.AssertionInput{
		Assertion: assertion, PublicKey: key.PublicKey, ClientDataHash: sha256Bytes(framing), AppID: PrivacyAppID(a.teamID),
	})
	if err != nil {
		return a.failQuarantine(ctx, providerID, now, ReasonAppAttestAssertionInvalid)
	}
	if counter <= key.LastCounter {
		return a.failQuarantine(ctx, providerID, now, ReasonAppAttestCounterRegression)
	}
	if err := a.store.AdvanceAppAttestCounter(ctx, providerID, keyID, counter); err != nil {
		a.NoteChallengeTimeout(providerID, session)
		return privacyReject("posture_counter_not_committed")
	}
	if !a.commitPosture(id, snap, statement.PostureStatement, PrivacyAssuranceCodeBound, now) {
		return privacyReject("posture_closed")
	}
	if counter == MaxAppAttestCounter {
		if _, err := a.store.RevokeAppAttestKey(ctx, providerID, keyID, ReasonCounterExhausted, now); err != nil {
			a.NoteChallengeTimeout(providerID, session)
			return err
		}
		a.endEnrollment(id, keyID)
	}
	return nil
}

// bindingCurrent is the SPEC-049-R029 pin and team comparison.
func (a *PrivacyAuthority) bindingCurrent(key AppAttestKey, providerID string) bool {
	sePin, hasSE := a.sePins[providerID]
	idPub, hasID := a.identity[providerID]
	return hasSE && hasID && key.TeamID == a.teamID &&
		bytes.Equal(key.SEPublicKeySHA256, sha256Bytes(sePin)) &&
		bytes.Equal(key.IdentityPublicKeySHA256, sha256Bytes(idPub))
}

// enrolledKeyUsable re-reads the durable key for a label decision. A store
// error is not usable (SPEC-049-R033).
func (a *PrivacyAuthority) enrolledKeyUsable(providerID string, keyID []byte) bool {
	if !a.CodeBoundActive() || len(keyID) != 32 {
		return false
	}
	key, found, err := a.store.AppAttestKeyByID(context.Background(), keyID)
	return err == nil && found && key.ProviderID == providerID && key.State == AppAttestKeyActive && a.bindingCurrent(key, providerID)
}

// childApproved matches the supervised child against approved identities
// for the configured team and the compiled child identifier.
func (a *PrivacyAuthority) childApproved(cdhash string, now time.Time) bool {
	for _, identity := range a.identities {
		if identity.TeamID == a.teamID && identity.SigningIdentifier == PrivacyChildSigningIdentifier &&
			identity.CDHash == cdhash && identity.ExpiresAt.After(now) {
			return true
		}
	}
	return false
}

func (a *PrivacyAuthority) sessionEnrolled(id privacySessionID) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	return entry != nil && entry.enrolled
}

func (a *PrivacyAuthority) takeEnrollment(id privacySessionID) pendingEnrollment {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil {
		return pendingEnrollment{}
	}
	pending := entry.enroll
	entry.enroll = pendingEnrollment{}
	return pending
}

// setEnrolled enters the enrolled state. The Beta posture ends here: the
// session is ineligible until a version 2 posture verifies (SPEC-049-R024).
func (a *PrivacyAuthority) setEnrolled(id privacySessionID, keyID []byte) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil || a.closedGen[id] != entry.boundGen {
		return false
	}
	entry.enrolled = true
	entry.enrolledKeyID = append([]byte(nil), keyID...)
	entry.verified = false
	entry.digests = nil
	entry.label = ""
	entry.generation = a.nextGenerationLocked()
	return true
}

// endEnrollment leaves the enrolled state and tells the live session to
// re-enroll (SPEC-049-R033). The session is ineligible until a new posture.
func (a *PrivacyAuthority) endEnrollment(id privacySessionID, keyID []byte) {
	a.mu.Lock()
	entry := a.sessions[id]
	if entry != nil {
		entry.enrolled = false
		entry.enrolledKeyID = nil
		entry.verified = false
		entry.digests = nil
		entry.label = ""
		entry.generation = a.nextGenerationLocked()
	}
	a.mu.Unlock()
	a.notifyMu.Lock()
	notify := a.notify
	a.notifyMu.Unlock()
	if notify != nil {
		notify(id.providerID, id.session, base64.RawURLEncoding.EncodeToString(keyID), AppAttestReenrollRequired)
	}
}

// PendingEnrollmentKeyID returns the keyId of the session's outstanding
// enrollment challenge, so the result can echo it. Empty when none.
func (a *PrivacyAuthority) PendingEnrollmentKeyID(providerID, session string) string {
	if a == nil {
		return ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[privacySessionID{providerID: providerID, session: session}]
	if entry == nil || !entry.enroll.active {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(entry.enroll.keyID)
}
