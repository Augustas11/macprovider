package relayblind

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

const (
	privacyPostureResponseType = "privacy_posture_response"
	privacyClockSkewSeconds    = int64(30)
)

var (
	ErrPrivacyRejected    = errors.New("relayblind: privacy posture rejected")
	ErrPrivacyQuarantined = errors.New("relayblind: privacy provider quarantined")
)

// PrivacyAuthority verifies privacy-class key advertisements and posture
// responses. Eligibility is in memory and dies on restart or DropSession.
type PrivacyAuthority struct {
	store           *Store
	sePins          map[string][]byte
	identity        map[string]ed25519.PublicKey
	identities      []config.ApprovedCodeIdentity
	denied          map[string]struct{}
	backends        map[string]struct{}
	interval        int
	maxAge          int
	timeout         int
	quarantine      int
	maxRecords      int
	replayRetention time.Duration

	// SPEC-049-R027 release-derived approvals, refreshed from signed
	// pearl-release.json files. Read-mostly; guarded separately from mu.
	releaseMu  sync.RWMutex
	release    []config.ApprovedCodeIdentity
	releaseDir string
	releaseKey *ecdsa.PublicKey
	directory  *IdentityDirectoryService

	mu                sync.Mutex
	pendingQuarantine map[string]pendingQuarantine
	sessions          map[privacySessionID]*privacySession
	epochs            map[string]uint64
	closedGen         map[privacySessionID]uint64
	generation        uint64
	quarantineSeq     uint64
}

type privacySessionID struct {
	providerID string
	session    string
}

type privacySession struct {
	generation   uint64
	boundGen     uint64
	epoch        uint64
	verified     bool
	verifiedAt   time.Time
	cdhash       string
	hasCDHash    bool
	teamID       string
	signingID    string
	binary       string
	digests      map[string]struct{}
	seq          uint64
	hasSeq       bool
	nonce        string
	nonceIssued  int64
	hasNonce     bool
	attestations map[string]string
	claim        *PrivacyEnrollmentClaim
}

type postureSnapshot struct {
	generation   uint64
	boundGen     uint64
	epoch        uint64
	seq          uint64
	hasSeq       bool
	cdhash       string
	hasCDHash    bool
	attestations map[string]string
	claim        *PrivacyEnrollmentClaim
	issuedAt     int64
}

func NewPrivacyAuthority(store *Store, cfg config.PrivacyClassConfig, identityPins map[string]string, maxRecords int, replayRetention time.Duration) (*PrivacyAuthority, error) {
	if store == nil {
		return nil, ErrStoreUnavailable
	}
	if maxRecords <= 0 || maxRecords > MaxPrivacyKeyRecordDigests {
		maxRecords = MaxPrivacyKeyRecordDigests
	}
	if replayRetention <= 0 {
		replayRetention = 5 * time.Minute
	}
	sePins := make(map[string][]byte, len(cfg.ProviderSEPublicKeys))
	for rawID, encoded := range cfg.ProviderSEPublicKeys {
		providerID := strings.TrimSpace(rawID)
		decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
		if providerID == "" || err != nil || len(decoded) != 64 || base64.StdEncoding.EncodeToString(decoded) != encoded {
			return nil, fmt.Errorf("relayblind: invalid privacy SE pin for provider %q", rawID)
		}
		x := new(big.Int).SetBytes(decoded[:32])
		y := new(big.Int).SetBytes(decoded[32:])
		if !elliptic.P256().IsOnCurve(x, y) {
			return nil, fmt.Errorf("relayblind: invalid privacy SE pin for provider %q", rawID)
		}
		sePins[providerID] = append([]byte(nil), decoded...)
	}
	identity := make(map[string]ed25519.PublicKey, len(identityPins))
	for rawID, encoded := range identityPins {
		providerID := strings.TrimSpace(rawID)
		decoded, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
		if providerID == "" || err != nil || len(decoded) != ed25519.PublicKeySize || base64.RawURLEncoding.EncodeToString(decoded) != encoded {
			return nil, fmt.Errorf("relayblind: invalid identity pin for provider %q", rawID)
		}
		identity[providerID] = append(ed25519.PublicKey(nil), decoded...)
	}
	denied := make(map[string]struct{}, len(cfg.DeniedCodeCDHashes))
	for _, cdhash := range cfg.DeniedCodeCDHashes {
		denied[cdhash] = struct{}{}
	}
	backends := make(map[string]struct{}, len(cfg.AllowedSEKeyBackends))
	for _, backend := range cfg.AllowedSEKeyBackends {
		backends[backend] = struct{}{}
	}
	interval := cfg.PostureChallengeIntervalSeconds
	if interval <= 0 {
		interval = 60
	}
	maxAge := cfg.PostureMaxAgeSeconds
	if maxAge <= 0 {
		maxAge = 150
	}
	timeout := cfg.PostureResponseTimeoutSeconds
	if timeout <= 0 {
		timeout = 10
	}
	quarantine := cfg.QuarantineSeconds
	if quarantine <= 0 {
		quarantine = 86400
	}
	authority := &PrivacyAuthority{
		store:             store,
		sePins:            sePins,
		identity:          identity,
		identities:        append([]config.ApprovedCodeIdentity(nil), cfg.ApprovedCodeIdentities...),
		denied:            denied,
		backends:          backends,
		interval:          interval,
		maxAge:            maxAge,
		timeout:           timeout,
		quarantine:        quarantine,
		maxRecords:        maxRecords,
		replayRetention:   replayRetention,
		sessions:          make(map[privacySessionID]*privacySession),
		epochs:            make(map[string]uint64),
		closedGen:         make(map[privacySessionID]uint64),
		pendingQuarantine: make(map[string]pendingQuarantine),
	}
	// SPEC-049-R027: a configured release signing key that cannot be read
	// or parsed is a startup failure, never a silent empty approval set.
	if cfg.ReleaseCodeIdentities.Configured() {
		raw, err := os.ReadFile(cfg.ReleaseCodeIdentities.PublicKeyPath)
		if err != nil {
			return nil, fmt.Errorf("relayblind: release signing public key unreadable: %w", err)
		}
		key, err := ParseReleaseSigningPublicKey(raw)
		if err != nil {
			return nil, err
		}
		authority.releaseMu.Lock()
		authority.releaseDir, authority.releaseKey = cfg.ReleaseCodeIdentities.MetadataDir, key
		authority.releaseMu.Unlock()
		authority.RefreshReleaseIdentities()
	}
	// SPEC-049-R028: the directory signer is loaded with the authority so
	// the buyer route and the enrollment state share one owner.
	if strings.TrimSpace(cfg.Directory.SigningKeyPath) != "" {
		key, err := LoadIdentityDirectorySigningKey(cfg.Directory.SigningKeyPath)
		if err != nil {
			return nil, err
		}
		ttl := time.Duration(cfg.Directory.TTLSeconds) * time.Second
		if ttl == 0 {
			ttl = 300 * time.Second
		}
		if err := authority.UseIdentityDirectoryKey(key, ttl); err != nil {
			return nil, err
		}
	}
	return authority, nil
}

// UseIdentityDirectoryKey installs the SPEC-049-R028 directory signer.
func (a *PrivacyAuthority) UseIdentityDirectoryKey(key ed25519.PrivateKey, ttl time.Duration) error {
	if a == nil {
		return ErrStoreUnavailable
	}
	service, err := NewIdentityDirectoryService(a, key, ttl)
	if err != nil {
		return err
	}
	a.directory = service
	return nil
}

// IdentityDirectory returns the directory signer, or nil when none is loaded.
func (a *PrivacyAuthority) IdentityDirectory() *IdentityDirectoryService {
	if a == nil {
		return nil
	}
	return a.directory
}

func (a *PrivacyAuthority) ChallengeInterval() time.Duration {
	if a == nil || a.interval <= 0 {
		return 60 * time.Second
	}
	return time.Duration(a.interval) * time.Second
}

func (a *PrivacyAuthority) ResponseTimeout() time.Duration {
	if a == nil || a.timeout <= 0 {
		return 10 * time.Second
	}
	return time.Duration(a.timeout) * time.Second
}

func (a *PrivacyAuthority) CandidateSessions(ctx context.Context, now time.Time) ([]KeySession, error) {
	if a == nil || a.store == nil {
		return nil, ErrStoreUnavailable
	}
	return a.store.FreshKeySessions(privacyCtx(ctx), now, KeyClassPrivacy)
}

// AcceptPrivacyKeys accepts an advertisement without an enrollment claim,
// so only configured pins or an existing enrollment can verify it.
func (a *PrivacyAuthority) AcceptPrivacyKeys(ctx context.Context, providerID, session string, recs []PrivacyKeyRecord, now time.Time) error {
	return a.AcceptPrivacyKeysWithClaim(ctx, providerID, session, recs, nil, now)
}

// AcceptPrivacyKeysWithClaim verifies privacy key records against the
// identity key resolved by SPEC-049-R004. A claim only names enrollment
// candidates; it never enrolls (SPEC-049-R025). A claim that differs from an
// active enrollment quarantines (SPEC-049-R026).
func (a *PrivacyAuthority) AcceptPrivacyKeysWithClaim(ctx context.Context, providerID, session string, recs []PrivacyKeyRecord, claim *PrivacyEnrollmentClaim, now time.Time) error {
	if a == nil || a.store == nil {
		return ErrStoreUnavailable
	}
	ctx = privacyCtx(ctx)
	id := privacySessionID{providerID: providerID, session: session}
	if len(recs) == 0 {
		err := a.store.RevokeMissingKeys(ctx, providerID, nil, now, a.replayRetention, KeyClassPrivacy)
		a.forgetAdvertisement(id)
		return err
	}
	if providerID == "" || session == "" {
		return ErrStaleSession
	}
	if len(recs) > a.maxRecords {
		return ErrCapacity
	}
	quarantined, err := a.isQuarantined(ctx, providerID, now)
	if err != nil {
		return err
	}
	if quarantined {
		return ErrPrivacyQuarantined
	}
	keys, changed, err := a.resolveKeys(ctx, providerID, claim)
	if err != nil {
		return err
	}
	if changed {
		return a.failQuarantine(ctx, providerID, now, "privacy_enrollment_key_changed")
	}
	// Before enrollment the claim is this session's only key source, so it
	// must not change mid-session: records verified under an earlier claim
	// would otherwise sit beside a posture enrolled under a later one.
	if keys.needsEnrollment() && a.sessionClaimChanged(id, claim) {
		revokeErr := a.store.RevokeMissingKeys(ctx, providerID, nil, now, a.replayRetention, KeyClassPrivacy)
		a.forgetAdvertisement(id)
		if revokeErr != nil {
			return revokeErr
		}
		return privacyReject("privacy_enrollment_claim_changed")
	}
	publicKey := keys.identity
	if publicKey == nil {
		return fmt.Errorf("%w: provider has no operator pin, enrollment, or claim", ErrInvalidPin)
	}
	type accepted struct {
		record          PrivacyKeyRecord
		immutableDigest string
	}
	verified := make([]accepted, 0, len(recs))
	seenKid := make(map[string]struct{}, len(recs))
	seenDigest := make(map[string]struct{}, len(recs))
	for _, rec := range recs {
		if _, dup := seenKid[rec.KeyRecord.KID]; dup {
			return fmt.Errorf("%w: duplicate kid", ErrInvalidKeyRecord)
		}
		seenKid[rec.KeyRecord.KID] = struct{}{}
		if _, dup := seenDigest[rec.KeyRecord.KeyRecordDigest]; dup {
			return fmt.Errorf("%w: duplicate key digest", ErrInvalidKeyRecord)
		}
		seenDigest[rec.KeyRecord.KeyRecordDigest] = struct{}{}
		pin := identityPinFor(publicKey, rec.KeyRecord)
		if err := rec.KeyRecord.Verify(pin, now); err != nil {
			return err
		}
		if err := rec.Attestation.Verify(pin, rec.Signature, rec.KeyRecord); err != nil {
			return err
		}
		if previous, found, err := a.store.ExistingKeyRecord(ctx, providerID, rec.KeyRecord.KID); err != nil {
			return err
		} else if found && previous.KeyRecordDigest != rec.KeyRecord.KeyRecordDigest {
			if err := ValidateKeyRenewal(previous, rec.KeyRecord, pin, now); err != nil {
				return err
			}
		}
		framing, err := rec.KeyRecord.ImmutableFraming()
		if err != nil {
			return err
		}
		digest := sha256.Sum256(framing)
		verified = append(verified, accepted{record: rec, immutableDigest: base64.RawURLEncoding.EncodeToString(digest[:])})
	}
	postureCD, hasPosture := a.verifiedCDHash(id)
	for _, item := range verified {
		switch a.approve("", "", item.record.Attestation.CodeCDHash, item.record.Attestation.BinaryVersion, false, now) {
		case approvalDenied:
			return a.failQuarantine(ctx, providerID, now, "posture_denied_code_identity")
		case approvalNone:
			// SPEC-049-R006: not yet approved is refused without quarantine.
			return privacyReject("posture_unapproved_code_identity")
		}
		if hasPosture && item.record.Attestation.CodeCDHash != postureCD {
			return a.failQuarantine(ctx, providerID, now, "posture_attestation_cdhash_mismatch")
		}
	}
	sort.Slice(verified, func(i, j int) bool { return verified[i].record.KeyRecord.KID < verified[j].record.KeyRecord.KID })
	for _, item := range verified {
		if err := a.store.UpsertKeyRecordClass(ctx, providerID, session, item.record.KeyRecord, item.immutableDigest, now, a.maxRecords, a.replayRetention, KeyClassPrivacy); err != nil {
			return err
		}
		if err := a.store.StorePrivacyAttestation(ctx, providerID, item.record.KeyRecord.KID, item.record.KeyRecord.KeyRecordDigest, item.record.Attestation, item.record.Signature); err != nil {
			return err
		}
	}
	kids := make([]string, 0, len(verified))
	attestations := make(map[string]string, len(verified))
	for _, item := range verified {
		kids = append(kids, item.record.KeyRecord.KID)
		attestations[item.record.KeyRecord.KeyRecordDigest] = item.record.Attestation.CodeCDHash
	}
	if err := a.store.RevokeMissingKeys(ctx, providerID, kids, now, a.replayRetention, KeyClassPrivacy); err != nil {
		return err
	}
	a.storeAdvertisement(id, attestations, claim)
	return nil
}

type resolvedPrivacyKeys struct {
	identity       ed25519.PublicKey
	se             []byte
	identityPinned bool
	sePinned       bool
	enrolled       bool
}

// needsEnrollment is SPEC-049-R025: no active enrollment and at least one key
// that configuration does not pin.
func (k resolvedPrivacyKeys) needsEnrollment() bool {
	return !k.enrolled && !(k.identityPinned && k.sePinned)
}

// resolveKeys applies SPEC-049-R004 precedence per key: configuration pin,
// then active enrollment, then the session's enrollment claim. changed
// reports a claim that differs from the active enrollment on a key that
// configuration does not pin (SPEC-049-R026).
func (a *PrivacyAuthority) resolveKeys(ctx context.Context, providerID string, claim *PrivacyEnrollmentClaim) (resolvedPrivacyKeys, bool, error) {
	var keys resolvedPrivacyKeys
	if pinned, ok := a.identity[providerID]; ok {
		keys.identity, keys.identityPinned = pinned, true
	}
	if pinned, ok := a.sePins[providerID]; ok {
		keys.se, keys.sePinned = pinned, true
	}
	if keys.identityPinned && keys.sePinned {
		return keys, false, nil
	}
	enrollment, enrolled, err := a.store.ActivePrivacyEnrollment(ctx, providerID)
	if err != nil {
		return resolvedPrivacyKeys{}, false, err
	}
	if enrolled {
		keys.enrolled = true
		changed := false
		if claim != nil {
			if !keys.identityPinned && claim.IdentityPublicKey != enrollment.IdentityPublicKey {
				changed = true
			}
			if !keys.sePinned && claim.SEPublicKey != enrollment.SEPublicKey {
				changed = true
			}
		}
		if !keys.identityPinned {
			decoded, err := decodeBase64URLFixed(enrollment.IdentityPublicKey, ed25519.PublicKeySize)
			if err != nil {
				return resolvedPrivacyKeys{}, false, fmt.Errorf("%w: stored enrollment identity", ErrStoreUnavailable)
			}
			keys.identity = ed25519.PublicKey(decoded)
		}
		if !keys.sePinned {
			decoded, err := DecodeSEPublicKey(enrollment.SEPublicKey)
			if err != nil {
				return resolvedPrivacyKeys{}, false, fmt.Errorf("%w: stored enrollment secure enclave key", ErrStoreUnavailable)
			}
			keys.se = decoded
		}
		return keys, changed, nil
	}
	if claim != nil {
		if !keys.identityPinned {
			if decoded, err := decodeBase64URLFixed(claim.IdentityPublicKey, ed25519.PublicKeySize); err == nil {
				keys.identity = ed25519.PublicKey(decoded)
			}
		}
		if !keys.sePinned {
			if decoded, err := DecodeSEPublicKey(claim.SEPublicKey); err == nil {
				keys.se = decoded
			}
		}
	}
	return keys, false, nil
}

func (a *PrivacyAuthority) BeginChallenge(providerID, session string, now time.Time) (string, int64, error) {
	if a == nil {
		return "", 0, ErrStoreUnavailable
	}
	if providerID == "" || session == "" {
		return "", 0, ErrStaleSession
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", 0, err
	}
	nonce := base64.RawURLEncoding.EncodeToString(buf)
	issued := now.Unix()
	id := privacySessionID{providerID: providerID, session: session}
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.ensureLocked(id)
	entry.nonce = nonce
	entry.nonceIssued = issued
	entry.hasNonce = true
	entry.generation = a.nextGenerationLocked()
	entry.boundGen = a.closedGen[id]
	entry.epoch = a.epochs[providerID]
	return nonce, issued, nil
}

func (a *PrivacyAuthority) NoteChallengeTimeout(providerID, session string) {
	if a == nil {
		return
	}
	id := privacySessionID{providerID: providerID, session: session}
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil {
		return
	}
	entry.hasNonce = false
	entry.nonce = ""
	entry.verified = false
	entry.digests = nil
	entry.generation = a.nextGenerationLocked()
}

func (a *PrivacyAuthority) DropSession(providerID, session string) {
	if a == nil {
		return
	}
	id := privacySessionID{providerID: providerID, session: session}
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.sessions, id)
	a.closedGen[id]++
}

func (a *PrivacyAuthority) VerifyPosture(ctx context.Context, providerID, session, nonce string, raw []byte, sessionSEKey []byte, now time.Time) error {
	if a == nil || a.store == nil {
		return ErrStoreUnavailable
	}
	ctx = privacyCtx(ctx)
	if len(raw) == 0 || len(raw) > MaxPrivacyPostureResponseBytes {
		return privacyReject("posture_closed")
	}
	response, err := parsePrivacyPostureResponse(raw)
	if err != nil {
		return privacyReject("posture_closed")
	}
	statement, err := ParsePostureStatement(response.Statement)
	if err != nil {
		return privacyReject("posture_closed")
	}
	id := privacySessionID{providerID: providerID, session: session}
	snap, ok := a.consumeChallenge(id, nonce, statement.Nonce)
	if !ok {
		return privacyReject("posture_nonce_mismatch")
	}
	framing, err := statement.Framing()
	if err != nil {
		return privacyReject("posture_closed")
	}
	keys, changed, err := a.resolveKeys(ctx, providerID, snap.claim)
	if err != nil {
		a.NoteChallengeTimeout(providerID, session)
		return err
	}
	if changed {
		return a.failQuarantine(ctx, providerID, now, "privacy_enrollment_key_changed")
	}
	sePin, idPub := keys.se, keys.identity
	if sePin == nil || idPub == nil {
		return privacyReject("posture_pin_missing")
	}
	if !verifySEPosture(sePin, framing, response.SESignature) || !verifyIdentityPosture(idPub, framing, response.IdentitySignature) {
		return a.failQuarantine(ctx, providerID, now, "posture_signature_failure")
	}
	// A consumed challenge that fails without quarantine also clears the
	// session's earlier posture, so eligibility never outlives a failed
	// re-check until max age.
	if statement.ProviderID != providerID || statement.AssignedSession != session {
		a.NoteChallengeTimeout(providerID, session)
		return privacyReject("posture_session_binding")
	}
	reason, quarantine := a.policyFailure(statement, snap, sessionSEKey, sePin, now)
	if reason != "" {
		if quarantine {
			return a.failQuarantine(ctx, providerID, now, reason)
		}
		a.NoteChallengeTimeout(providerID, session)
		return privacyReject(reason)
	}
	skewed := abs64(now.Unix()-statement.IssuedAtUnix) > privacyClockSkewSeconds
	late := a.late(now.Unix(), snap.issuedAt)
	backendOK := a.backendAllowed(statement.SEKeyBackend)
	if late || skewed || !backendOK {
		a.NoteChallengeTimeout(providerID, session)
	}
	if skewed {
		return privacyReject("posture_clock_skew")
	}
	if !backendOK {
		return privacyReject("posture_key_backend")
	}
	if late {
		return privacyReject("posture_timeout")
	}
	disabled, err := a.store.PrivacyDisabled(ctx)
	if err != nil {
		a.NoteChallengeTimeout(providerID, session)
		return err
	}
	if disabled {
		a.NoteChallengeTimeout(providerID, session)
		return privacyReject("privacy_class_disabled")
	}
	quarantined, err := a.isQuarantined(ctx, providerID, now)
	if err != nil {
		a.NoteChallengeTimeout(providerID, session)
		return err
	}
	if quarantined {
		a.NoteChallengeTimeout(providerID, session)
		return ErrPrivacyQuarantined
	}
	if keys.needsEnrollment() {
		// SPEC-049-R025: only a still-current session whose listed keys are
		// still fresh may enroll. A replaced session, or one whose keys a
		// concurrent reenroll revoked, cannot write an enrollment.
		if !a.postureStillCurrent(id, snap) {
			a.NoteChallengeTimeout(providerID, session)
			return privacyReject("posture_closed")
		}
		// The enrollment is durable before this posture counts as verified,
		// and the store re-checks the listed keys' freshness inside the same
		// transaction, so a concurrent reenroll cannot interleave.
		err := a.store.EnrollPrivacyIdentityForSession(ctx, session, statement.PrivacyKeyRecordDigests, now, PrivacyEnrollment{
			ProviderID:          providerID,
			IdentityPublicKey:   encodeBase64URL(idPub),
			IdentityFingerprint: PublicKeyFingerprint(idPub),
			SEPublicKey:         base64.StdEncoding.EncodeToString(sePin),
			SEFingerprint:       PublicKeyFingerprint(sePin),
			TeamID:              statement.TeamID,
			SigningIdentifier:   statement.SigningIdentifier,
			CodeCDHash:          statement.CodeCDHash,
			BinaryVersion:       statement.BinaryVersion,
			EnrolledAtUnix:      now.Unix(),
		})
		switch {
		case errors.Is(err, ErrEnrollmentKeyChanged):
			return a.failQuarantine(ctx, providerID, now, "privacy_enrollment_key_changed")
		case errors.Is(err, ErrEnrollmentKeyInUse):
			a.NoteChallengeTimeout(providerID, session)
			return privacyReject("privacy_enrollment_key_in_use")
		case errors.Is(err, ErrEnrollmentKeysStale):
			a.NoteChallengeTimeout(providerID, session)
			return privacyReject("posture_keys_stale")
		case err != nil:
			a.NoteChallengeTimeout(providerID, session)
			return err
		}
	}
	if !a.commitPosture(id, snap, statement, now) {
		return privacyReject("posture_closed")
	}
	return nil
}

func (a *PrivacyAuthority) Eligible(providerID, session, keyDigest string, now time.Time) (time.Time, bool) {
	if a == nil || a.store == nil || keyDigest == "" {
		return time.Time{}, false
	}
	id := privacySessionID{providerID: providerID, session: session}
	a.mu.Lock()
	entry := a.sessions[id]
	if entry == nil || !entry.verified {
		a.mu.Unlock()
		return time.Time{}, false
	}
	verifiedAt := entry.verifiedAt
	teamID, signingID, cdhash, binary := entry.teamID, entry.signingID, entry.cdhash, entry.binary
	_, listed := entry.digests[keyDigest]
	a.mu.Unlock()
	if !listed || now.Sub(verifiedAt) > time.Duration(a.maxAge)*time.Second {
		return time.Time{}, false
	}
	if !a.identityMatches(teamID, signingID, cdhash, binary, now) {
		return time.Time{}, false
	}
	ctx := context.Background()
	disabled, err := a.store.PrivacyDisabled(ctx)
	if err != nil || disabled {
		return time.Time{}, false
	}
	quarantined, err := a.isQuarantined(ctx, providerID, now)
	if err != nil || quarantined {
		return time.Time{}, false
	}
	fresh, err := a.store.PrivacyKeyFresh(ctx, providerID, session, keyDigest, now)
	if err != nil || !fresh {
		return time.Time{}, false
	}
	return verifiedAt, true
}

func (a *PrivacyAuthority) identityMatches(teamID, signingID, cdhash, binary string, now time.Time) bool {
	return a.approve(teamID, signingID, cdhash, binary, true, now) == approvalApproved
}

type codeApproval int

const (
	approvalNone codeApproval = iota
	approvalApproved
	approvalDenied
)

// approve is SPEC-049-R006: the deny list wins; configuration entries for
// the same identity govern (an expired entry withdraws approval); otherwise
// a release-derived identity with the same binary version approves. A key
// attestation carries no team, so it is matched with requireTeam false.
func (a *PrivacyAuthority) approve(teamID, signingID, cdhash, binary string, requireTeam bool, now time.Time) codeApproval {
	if _, denied := a.denied[cdhash]; denied {
		return approvalDenied
	}
	configured := false
	for _, identity := range a.identities {
		if identity.CDHash != cdhash {
			continue
		}
		if requireTeam && (identity.TeamID != teamID || identity.SigningIdentifier != signingID) {
			continue
		}
		configured = true
		if identity.ExpiresAt.After(now) && (identity.BinaryVersion == "" || identity.BinaryVersion == binary) {
			return approvalApproved
		}
	}
	if configured {
		return approvalNone
	}
	a.releaseMu.RLock()
	defer a.releaseMu.RUnlock()
	for _, identity := range a.release {
		if identity.CDHash != cdhash || identity.BinaryVersion != binary {
			continue
		}
		if requireTeam && (identity.TeamID != teamID || identity.SigningIdentifier != signingID) {
			continue
		}
		return approvalApproved
	}
	return approvalNone
}

// ConfigureReleaseIdentities sets the SPEC-049-R027 source and loads it once.
func (a *PrivacyAuthority) ConfigureReleaseIdentities(dir string, key *ecdsa.PublicKey) ReleaseIdentityLoad {
	if a == nil {
		return ReleaseIdentityLoad{}
	}
	a.releaseMu.Lock()
	a.releaseDir, a.releaseKey = dir, key
	a.releaseMu.Unlock()
	return a.RefreshReleaseIdentities()
}

// ReleaseIdentityLoad reports one release-derived reload. Rejected holds
// file names only, never content.
type ReleaseIdentityLoad struct {
	Configured bool
	Identities int
	Rejected   []string
	Err        error
}

// RefreshReleaseIdentities reloads release-derived approvals. A directory
// error leaves an empty set until the next successful load (fail closed).
func (a *PrivacyAuthority) RefreshReleaseIdentities() ReleaseIdentityLoad {
	if a == nil {
		return ReleaseIdentityLoad{}
	}
	a.releaseMu.RLock()
	dir, key := a.releaseDir, a.releaseKey
	a.releaseMu.RUnlock()
	if dir == "" || key == nil {
		return ReleaseIdentityLoad{}
	}
	identities, rejected, err := LoadReleaseCodeIdentities(dir, key)
	a.releaseMu.Lock()
	a.release = identities
	a.releaseMu.Unlock()
	return ReleaseIdentityLoad{Configured: true, Identities: len(identities), Rejected: rejected, Err: err}
}

// policyFailure returns the first failing check and whether it quarantines.
// Only an unapproved, not denied, code identity is refused without one.
func (a *PrivacyAuthority) policyFailure(statement PostureStatement, snap postureSnapshot, sessionSEKey, sePin []byte, now time.Time) (string, bool) {
	approval := a.approve(statement.TeamID, statement.SigningIdentifier, statement.CodeCDHash, statement.BinaryVersion, true, now)
	if approval == approvalDenied {
		return "posture_denied_code_identity", true
	}
	if !requiredPosture(statement) {
		return "posture_required_value", true
	}
	if snap.hasSeq && statement.Sequence <= snap.seq {
		return "posture_sequence_regression", true
	}
	if snap.hasCDHash && statement.CodeCDHash != snap.cdhash {
		return "posture_cdhash_changed", true
	}
	for _, attested := range snap.attestations {
		if attested != statement.CodeCDHash {
			return "posture_attestation_cdhash_mismatch", true
		}
	}
	if seKeyMismatch(sessionSEKey, sePin) {
		return "posture_se_key_mismatch", true
	}
	if approval != approvalApproved {
		return "posture_unapproved_code_identity", false
	}
	return "", false
}

func requiredPosture(statement PostureStatement) bool {
	return statement.HardenedRuntime && statement.LibraryValidation && statement.PTDenyAttachApplied &&
		statement.CoreDumpsDisabled && statement.SIPEnabled && statement.DiagnosticEnvClear &&
		statement.KVDiskTierDisabled && !statement.GetTaskAllow && !statement.CSDebugged && !statement.PTraced
}

func (a *PrivacyAuthority) failQuarantine(ctx context.Context, providerID string, now time.Time, reason string) error {
	if err := a.recordQuarantine(ctx, providerID, now, reason); err != nil {
		return err
	}
	return fmt.Errorf("%w: %s", ErrPrivacyQuarantined, reason)
}

func (a *PrivacyAuthority) recordQuarantine(ctx context.Context, providerID string, now time.Time, reason string) error {
	dur := time.Duration(a.quarantine) * time.Second
	a.mu.Lock()
	a.quarantineSeq++
	token := a.quarantineSeq
	a.mu.Unlock()
	clearGeneration, clearGenErr := a.store.OperatorClearGeneration(ctx, providerID)
	// The in-memory invalidation runs even when the store write fails, so a
	// posture failure never leaves the live session eligible.
	writeErr := a.store.QuarantineAndRevokePrivacy(ctx, providerID, reason, now, dur, a.replayRetention)
	a.mu.Lock()
	// A failed durable write keeps an in-memory latch that blocks the
	// provider and retries the write until it lands.
	if writeErr != nil {
		if clearGenErr != nil {
			clearGeneration = unknownOperatorClearGeneration
		}
		if pending, ok := a.pendingQuarantine[providerID]; !ok || pending.token <= token {
			a.pendingQuarantine[providerID] = pendingQuarantine{reason: reason, clearGeneration: clearGeneration, token: token}
		}
	} else {
		a.deletePendingQuarantineThroughLocked(providerID, token)
	}
	a.epochs[providerID]++
	epoch := a.epochs[providerID]
	for id, entry := range a.sessions {
		if id.providerID != providerID {
			continue
		}
		entry.epoch = epoch
		entry.generation = a.nextGenerationLocked()
		entry.verified = false
		entry.digests = nil
		entry.attestations = nil
		entry.hasNonce = false
		entry.nonce = ""
	}
	a.mu.Unlock()
	return writeErr
}

func (a *PrivacyAuthority) consumeChallenge(id privacySessionID, nonce, statementNonce string) (postureSnapshot, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil || !entry.hasNonce || entry.nonce != nonce || statementNonce != nonce {
		return postureSnapshot{}, false
	}
	snap := postureSnapshot{
		generation:   entry.generation,
		boundGen:     entry.boundGen,
		epoch:        entry.epoch,
		seq:          entry.seq,
		hasSeq:       entry.hasSeq,
		cdhash:       entry.cdhash,
		hasCDHash:    entry.hasCDHash,
		attestations: copyAttestations(entry.attestations),
		claim:        entry.claim,
		issuedAt:     entry.nonceIssued,
	}
	entry.hasNonce = false
	entry.nonce = ""
	return snap, true
}

// isQuarantined is the durable quarantine plus the in-memory latch of a
// quarantine whose durable write failed. A latched provider stays
// quarantined; each check retries the durable write.
func (a *PrivacyAuthority) isQuarantined(ctx context.Context, providerID string, now time.Time) (bool, error) {
	a.mu.Lock()
	pending, latched := a.pendingQuarantine[providerID]
	a.mu.Unlock()
	if latched {
		// An operator unquarantine or reenroll after the latch wins. The
		// retry and the generation check are one transaction, so a retry
		// cannot re-create a quarantine that the operator already lifted.
		dur := time.Duration(a.quarantine) * time.Second
		cleared, err := a.store.RetryLatchedQuarantine(ctx, providerID, pending.reason, pending.clearGeneration, now, dur, a.replayRetention)
		if err == nil && cleared {
			a.mu.Lock()
			current := a.deletePendingQuarantineThroughLocked(providerID, pending.token)
			a.mu.Unlock()
			if !current {
				return true, nil
			}
			return a.store.IsQuarantined(ctx, providerID, now)
		}
		if err == nil {
			a.mu.Lock()
			a.deletePendingQuarantineThroughLocked(providerID, pending.token)
			a.mu.Unlock()
		}
		return true, nil
	}
	return a.store.IsQuarantined(ctx, providerID, now)
}

// pendingQuarantine is a quarantine whose durable write failed.
type pendingQuarantine struct {
	reason          string
	clearGeneration int64
	token           uint64
}

// unknownOperatorClearGeneration is intentionally above any practical operator
// clear sequence. If the baseline cannot be read, recovery fails closed: later
// checks may still make the quarantine durable, but they do not discard the
// latch merely because an operator-clear row exists.
const unknownOperatorClearGeneration int64 = 1 << 62

func (a *PrivacyAuthority) deletePendingQuarantineThroughLocked(providerID string, token uint64) bool {
	pending, ok := a.pendingQuarantine[providerID]
	if !ok {
		return true
	}
	if pending.token > token {
		return false
	}
	delete(a.pendingQuarantine, providerID)
	return true
}

// postureStillCurrent reports whether the session that received the
// challenge is still the live, unreplaced one the snapshot was taken from.
func (a *PrivacyAuthority) postureStillCurrent(id privacySessionID, snap postureSnapshot) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	return entry != nil && entry.generation == snap.generation && entry.boundGen == snap.boundGen &&
		entry.epoch == snap.epoch && a.epochs[id.providerID] == snap.epoch && a.closedGen[id] == snap.boundGen
}

func (a *PrivacyAuthority) commitPosture(id privacySessionID, snap postureSnapshot, statement PostureStatement, now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil || entry.generation != snap.generation || entry.boundGen != snap.boundGen || entry.epoch != snap.epoch {
		return false
	}
	if a.epochs[id.providerID] != snap.epoch || a.closedGen[id] != snap.boundGen {
		return false
	}
	entry.verified = true
	entry.verifiedAt = now
	entry.cdhash = statement.CodeCDHash
	entry.hasCDHash = true
	entry.teamID = statement.TeamID
	entry.signingID = statement.SigningIdentifier
	entry.binary = statement.BinaryVersion
	digests := make(map[string]struct{}, len(statement.PrivacyKeyRecordDigests))
	for _, digest := range statement.PrivacyKeyRecordDigests {
		digests[digest] = struct{}{}
	}
	entry.digests = digests
	entry.seq = statement.Sequence
	entry.hasSeq = true
	return true
}

func (a *PrivacyAuthority) verifiedCDHash(id privacySessionID) (string, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil || !entry.verified || !entry.hasCDHash {
		return "", false
	}
	return entry.cdhash, true
}

// sessionClaimChanged reports a claim that differs from the one this session
// already advertised. A first claim, or a repeat of the same one, is not a
// change.
func (a *PrivacyAuthority) sessionClaimChanged(id privacySessionID, claim *PrivacyEnrollmentClaim) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil || entry.claim == nil {
		return false
	}
	return claim == nil || *entry.claim != *claim
}

func (a *PrivacyAuthority) storeAdvertisement(id privacySessionID, attestations map[string]string, claim *PrivacyEnrollmentClaim) {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.ensureLocked(id)
	entry.attestations = attestations
	if claim != nil {
		copied := *claim
		entry.claim = &copied
	} else {
		entry.claim = nil
	}
}

func (a *PrivacyAuthority) forgetAdvertisement(id privacySessionID) {
	a.mu.Lock()
	defer a.mu.Unlock()
	entry := a.sessions[id]
	if entry == nil {
		return
	}
	entry.attestations = nil
	entry.claim = nil
	entry.verified = false
	entry.digests = nil
	entry.hasNonce = false
	entry.nonce = ""
	entry.generation = a.nextGenerationLocked()
}

func (a *PrivacyAuthority) ensureLocked(id privacySessionID) *privacySession {
	entry := a.sessions[id]
	if entry == nil {
		entry = &privacySession{epoch: a.epochs[id.providerID], boundGen: a.closedGen[id]}
		a.sessions[id] = entry
	}
	return entry
}

func (a *PrivacyAuthority) nextGenerationLocked() uint64 {
	a.generation++
	if a.generation == 0 {
		a.generation = 1
	}
	return a.generation
}

func (a *PrivacyAuthority) late(nowUnix, issuedAt int64) bool {
	elapsed := nowUnix - issuedAt
	return elapsed < 0 || elapsed > int64(a.timeout)
}

func (a *PrivacyAuthority) backendAllowed(backend string) bool {
	_, ok := a.backends[backend]
	return ok
}

func identityPinFor(publicKey ed25519.PublicKey, record KeyRecord) IdentityPin {
	fingerprint := sha256.Sum256(publicKey)
	return IdentityPin{
		Version:           PinVersion,
		IdentityPublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		Fingerprint:       base64.RawURLEncoding.EncodeToString(fingerprint[:]),
		Models:            append([]string(nil), record.Models...),
		EndpointFamilies:  []string{EndpointChatCompletions},
		NotBeforeUnix:     0,
		ExpiresAtUnix:     math.MaxInt64,
	}
}

func copyAttestations(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for digest, cdhash := range in {
		out[digest] = cdhash
	}
	return out
}

func seKeyMismatch(sessionSE, pin []byte) bool {
	if len(sessionSE) == 0 {
		return false
	}
	if len(sessionSE) != 64 || len(pin) != 64 {
		return true
	}
	return subtle.ConstantTimeCompare(sessionSE, pin) != 1
}

func verifySEPosture(pin, framing []byte, signatureB64 string) bool {
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(signatureB64)
	if err != nil || signatureB64 == "" || base64.RawURLEncoding.EncodeToString(decoded) != signatureB64 || len(pin) != 64 {
		return false
	}
	x := new(big.Int).SetBytes(pin[:32])
	y := new(big.Int).SetBytes(pin[32:])
	if !elliptic.P256().IsOnCurve(x, y) {
		return false
	}
	digest := sha256.Sum256(framing)
	pub := &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}
	return ecdsa.VerifyASN1(pub, digest[:], decoded)
}

func verifyIdentityPosture(publicKey ed25519.PublicKey, framing []byte, signatureB64 string) bool {
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(signatureB64)
	if err != nil || len(decoded) != ed25519.SignatureSize || base64.RawURLEncoding.EncodeToString(decoded) != signatureB64 {
		return false
	}
	return ed25519.Verify(publicKey, framing, decoded)
}

func privacyReject(reason string) error {
	return fmt.Errorf("%w: %s", ErrPrivacyRejected, reason)
}

func privacyCtx(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}

func abs64(value int64) int64 {
	if value < 0 {
		return -value
	}
	return value
}

type privacyPostureWire struct {
	Type              string          `json:"type"`
	Version           int             `json:"version"`
	Statement         json.RawMessage `json:"statement"`
	SESignature       string          `json:"se_signature"`
	IdentitySignature string          `json:"identity_signature"`
}

func parsePrivacyPostureResponse(raw []byte) (privacyPostureWire, error) {
	var response privacyPostureWire
	if err := decodeClosed(raw, &response, []string{"type", "version", "statement", "se_signature", "identity_signature"}); err != nil {
		return privacyPostureWire{}, err
	}
	if response.Type != privacyPostureResponseType || response.Version != 1 {
		return privacyPostureWire{}, ErrInvalidPrivacy
	}
	statement := bytesTrimSpace(response.Statement)
	if len(statement) == 0 || statement[0] != '{' {
		return privacyPostureWire{}, ErrInvalidPrivacy
	}
	return response, nil
}

func bytesTrimSpace(raw []byte) []byte {
	start := 0
	for start < len(raw) && (raw[start] == ' ' || raw[start] == '\n' || raw[start] == '\r' || raw[start] == '\t') {
		start++
	}
	end := len(raw)
	for end > start && (raw[end-1] == ' ' || raw[end-1] == '\n' || raw[end-1] == '\r' || raw[end-1] == '\t') {
		end--
	}
	return raw[start:end]
}
