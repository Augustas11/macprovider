package trustpool

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

const (
	DefaultOnCallConfirmationTTL = 90 * 24 * time.Hour
	onCallLastConfirmedSkew      = 5 * time.Minute
	onCallReadinessSchemaVersion = "macprovider.trustpool-oncall-readiness.v1"
)

var (
	ErrOnCallReadiness = errors.New("trustpool: on-call readiness rejected")
)

// OnCallReadiness is the SPEC-043-R008/R011 signed launch-environment
// on-call record. Operator HTTP/CLI production promote consults this row
// via RequireOnCallReadinessForPromotion. Store.PromotePool still does not;
// wiring that mapped path needs a recapture window.
type OnCallReadiness struct {
	OperationID                           string        `json:"operation_id"`
	LaunchEnvironmentID                   string        `json:"launch_environment_id"`
	RecordVersion                         string        `json:"record_version"`
	PrimaryOperatorContact                string        `json:"primary_operator_contact"`
	SecondaryOperatorContact              string        `json:"secondary_operator_contact"`
	BreakGlassEscalationPath              string        `json:"break_glass_escalation_path"`
	CompromiseNotificationChannel         string        `json:"compromise_notification_channel"`
	CreatorAgreementNotificationAck       string        `json:"creator_agreement_notification_commitment_ack"`
	CreatorEmergencyNotificationMechanism string        `json:"creator_emergency_notification_mechanism"`
	LastConfirmedAtUTC                    time.Time     `json:"last_confirmed_at_utc"`
	ConfirmationTTL                       time.Duration `json:"-"`
	ConfirmationTTLSeconds                int64         `json:"confirmation_ttl_seconds"`
	OperationsAuthorityPublicKey          string        `json:"operations_authority_public_key"`
	OperationsAuthoritySignature          string        `json:"operations_authority_signature"`
	RecordRevision                        uint64        `json:"record_revision,omitempty"`
	UpdatedAtUTC                          time.Time     `json:"updated_at_utc,omitempty"`
}

type onCallSignPayload struct {
	LaunchEnvironmentID                   string `json:"launch_environment_id"`
	RecordVersion                         string `json:"record_version"`
	PrimaryOperatorContact                string `json:"primary_operator_contact"`
	SecondaryOperatorContact              string `json:"secondary_operator_contact"`
	BreakGlassEscalationPath              string `json:"break_glass_escalation_path"`
	CompromiseNotificationChannel         string `json:"compromise_notification_channel"`
	CreatorAgreementNotificationAck       string `json:"creator_agreement_notification_commitment_ack"`
	CreatorEmergencyNotificationMechanism string `json:"creator_emergency_notification_mechanism"`
	LastConfirmedAtUTC                    string `json:"last_confirmed_at_utc"`
	ConfirmationTTLSeconds                int64  `json:"confirmation_ttl_seconds"`
	OperationsAuthorityPublicKey          string `json:"operations_authority_public_key"`
}

func (r OnCallReadiness) Expired(now time.Time) bool {
	if r.LastConfirmedAtUTC.IsZero() {
		return true
	}
	ttl := r.ttl()
	if ttl <= 0 {
		return true
	}
	return !now.UTC().Before(r.LastConfirmedAtUTC.UTC().Add(ttl))
}

func (r OnCallReadiness) ttl() time.Duration {
	if r.ConfirmationTTL > 0 {
		return r.ConfirmationTTL
	}
	if r.ConfirmationTTLSeconds > 0 {
		return time.Duration(r.ConfirmationTTLSeconds) * time.Second
	}
	return DefaultOnCallConfirmationTTL
}

func SignOnCallReadiness(priv ed25519.PrivateKey, rec OnCallReadiness) (OnCallReadiness, error) {
	if len(priv) != ed25519.PrivateKeySize {
		return OnCallReadiness{}, fmt.Errorf("%w: operations authority private key", ErrOnCallReadiness)
	}
	rec.OperationsAuthorityPublicKey = base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
	rec = normalizeOnCallReadiness(rec)
	preimage, err := onCallSignPreimage(rec)
	if err != nil {
		return OnCallReadiness{}, err
	}
	rec.OperationsAuthoritySignature = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, preimage))
	return rec, nil
}

func OnCallAuthorityKeySHA256(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return hex.EncodeToString(sum[:])
}

func normalizeOnCallReadiness(rec OnCallReadiness) OnCallReadiness {
	rec.OperationID = strings.TrimSpace(rec.OperationID)
	rec.LaunchEnvironmentID = strings.TrimSpace(rec.LaunchEnvironmentID)
	rec.RecordVersion = strings.TrimSpace(rec.RecordVersion)
	rec.PrimaryOperatorContact = strings.TrimSpace(rec.PrimaryOperatorContact)
	rec.SecondaryOperatorContact = strings.TrimSpace(rec.SecondaryOperatorContact)
	rec.BreakGlassEscalationPath = strings.TrimSpace(rec.BreakGlassEscalationPath)
	rec.CompromiseNotificationChannel = strings.TrimSpace(rec.CompromiseNotificationChannel)
	rec.CreatorAgreementNotificationAck = strings.TrimSpace(rec.CreatorAgreementNotificationAck)
	rec.CreatorEmergencyNotificationMechanism = strings.TrimSpace(rec.CreatorEmergencyNotificationMechanism)
	rec.OperationsAuthorityPublicKey = strings.TrimSpace(rec.OperationsAuthorityPublicKey)
	rec.OperationsAuthoritySignature = strings.TrimSpace(rec.OperationsAuthoritySignature)
	if rec.ConfirmationTTLSeconds <= 0 {
		if rec.ConfirmationTTL > 0 {
			rec.ConfirmationTTLSeconds = int64(rec.ConfirmationTTL / time.Second)
		} else {
			rec.ConfirmationTTLSeconds = int64(DefaultOnCallConfirmationTTL / time.Second)
		}
	}
	maxTTLSeconds := int64(DefaultOnCallConfirmationTTL / time.Second)
	if rec.ConfirmationTTLSeconds > 0 && rec.ConfirmationTTLSeconds <= maxTTLSeconds {
		rec.ConfirmationTTL = time.Duration(rec.ConfirmationTTLSeconds) * time.Second
	}
	if !rec.LastConfirmedAtUTC.IsZero() {
		rec.LastConfirmedAtUTC = rec.LastConfirmedAtUTC.UTC()
	}
	return rec
}

func onCallSignPreimage(rec OnCallReadiness) ([]byte, error) {
	payload := onCallSignPayload{
		LaunchEnvironmentID:                   rec.LaunchEnvironmentID,
		RecordVersion:                         rec.RecordVersion,
		PrimaryOperatorContact:                rec.PrimaryOperatorContact,
		SecondaryOperatorContact:              rec.SecondaryOperatorContact,
		BreakGlassEscalationPath:              rec.BreakGlassEscalationPath,
		CompromiseNotificationChannel:         rec.CompromiseNotificationChannel,
		CreatorAgreementNotificationAck:       rec.CreatorAgreementNotificationAck,
		CreatorEmergencyNotificationMechanism: rec.CreatorEmergencyNotificationMechanism,
		LastConfirmedAtUTC:                    rec.LastConfirmedAtUTC.UTC().Format(time.RFC3339Nano),
		ConfirmationTTLSeconds:                rec.ConfirmationTTLSeconds,
		OperationsAuthorityPublicKey:          rec.OperationsAuthorityPublicKey,
	}
	return json.Marshal(payload)
}

func validateOnCallReadiness(rec OnCallReadiness, allowedKeySHA256 string, now time.Time) error {
	if rec.OperationID == "" || rec.LaunchEnvironmentID == "" || rec.RecordVersion == "" {
		return fmt.Errorf("%w: missing identity fields", ErrOnCallReadiness)
	}
	if rec.PrimaryOperatorContact == "" || rec.SecondaryOperatorContact == "" || rec.BreakGlassEscalationPath == "" {
		return fmt.Errorf("%w: missing operator contacts", ErrOnCallReadiness)
	}
	if rec.CompromiseNotificationChannel == "" || rec.CreatorAgreementNotificationAck == "" || rec.CreatorEmergencyNotificationMechanism == "" {
		return fmt.Errorf("%w: missing notification fields", ErrOnCallReadiness)
	}
	observedNow := now.UTC()
	if rec.LastConfirmedAtUTC.IsZero() {
		return fmt.Errorf("%w: last_confirmed_at_utc required", ErrOnCallReadiness)
	}
	if rec.LastConfirmedAtUTC.After(observedNow.Add(onCallLastConfirmedSkew)) {
		return fmt.Errorf("%w: last_confirmed_at_utc is in the future", ErrOnCallReadiness)
	}
	maxTTLSeconds := int64(DefaultOnCallConfirmationTTL / time.Second)
	if rec.ConfirmationTTLSeconds <= 0 || rec.ConfirmationTTLSeconds > maxTTLSeconds {
		return fmt.Errorf("%w: confirmation_ttl must be in (0, 90d]", ErrOnCallReadiness)
	}
	if rec.Expired(observedNow) {
		return fmt.Errorf("%w: record expired", ErrOnCallReadiness)
	}
	if err := ValidatePromiseClaimsText(
		rec.LaunchEnvironmentID,
		rec.PrimaryOperatorContact,
		rec.SecondaryOperatorContact,
		rec.BreakGlassEscalationPath,
		rec.CompromiseNotificationChannel,
		rec.CreatorAgreementNotificationAck,
		rec.CreatorEmergencyNotificationMechanism,
	); err != nil {
		return err
	}
	pub, err := canonicalBase64(rec.OperationsAuthorityPublicKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("%w: operations authority public key", ErrOnCallReadiness)
	}
	sig, err := canonicalBase64(rec.OperationsAuthoritySignature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return fmt.Errorf("%w: operations authority signature", ErrOnCallReadiness)
	}
	allowed := strings.ToLower(strings.TrimSpace(allowedKeySHA256))
	if requireLowerHex64(allowed) != nil {
		return fmt.Errorf("%w: allowed authority key digest", ErrOnCallReadiness)
	}
	if OnCallAuthorityKeySHA256(ed25519.PublicKey(pub)) != allowed {
		return fmt.Errorf("%w: operations authority key is not allowlisted", ErrOnCallReadiness)
	}
	preimage, err := onCallSignPreimage(rec)
	if err != nil {
		return err
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), preimage, sig) {
		return fmt.Errorf("%w: operations authority signature", ErrOnCallReadiness)
	}
	return nil
}

func (s *Store) migrateLiveReadinessTables(ctx context.Context) error {
	if s == nil || s.db == nil {
		return ErrStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS trustpool_oncall_readiness (
    launch_environment_id TEXT PRIMARY KEY,
    operation_id TEXT NOT NULL UNIQUE,
    record_version TEXT NOT NULL,
    primary_operator_contact TEXT NOT NULL,
    secondary_operator_contact TEXT NOT NULL,
    break_glass_escalation_path TEXT NOT NULL,
    compromise_notification_channel TEXT NOT NULL,
    creator_agreement_notification_ack TEXT NOT NULL,
    creator_emergency_notification_mechanism TEXT NOT NULL,
    last_confirmed_at_utc TEXT NOT NULL,
    confirmation_ttl_seconds INTEGER NOT NULL,
    operations_authority_public_key TEXT NOT NULL,
    operations_authority_signature TEXT NOT NULL,
    record_revision INTEGER NOT NULL DEFAULT 0,
    updated_at_utc TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS trustpool_oncall_readiness_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id TEXT NOT NULL UNIQUE,
    launch_environment_id TEXT NOT NULL,
    record_version TEXT NOT NULL,
    primary_operator_contact TEXT NOT NULL,
    secondary_operator_contact TEXT NOT NULL,
    break_glass_escalation_path TEXT NOT NULL,
    compromise_notification_channel TEXT NOT NULL,
    creator_agreement_notification_ack TEXT NOT NULL,
    creator_emergency_notification_mechanism TEXT NOT NULL,
    last_confirmed_at_utc TEXT NOT NULL,
    confirmation_ttl_seconds INTEGER NOT NULL,
    operations_authority_public_key TEXT NOT NULL,
    operations_authority_signature TEXT NOT NULL,
    record_revision INTEGER NOT NULL DEFAULT 0,
    updated_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trustpool_oncall_readiness_history_env ON trustpool_oncall_readiness_history(launch_environment_id, id);
CREATE TABLE IF NOT EXISTS trustpool_reviewed_artifact_lifecycle (
    pool_id TEXT PRIMARY KEY,
    operation_id TEXT NOT NULL UNIQUE,
    owner TEXT NOT NULL,
    environment_class TEXT NOT NULL,
    next_review_due_utc TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    record_revision INTEGER NOT NULL DEFAULT 0,
    updated_at_utc TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS trustpool_reviewed_artifact_lifecycle_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id TEXT NOT NULL UNIQUE,
    pool_id TEXT NOT NULL,
    owner TEXT NOT NULL,
    environment_class TEXT NOT NULL,
    next_review_due_utc TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    record_revision INTEGER NOT NULL DEFAULT 0,
    updated_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trustpool_reviewed_artifact_lifecycle_history_pool ON trustpool_reviewed_artifact_lifecycle_history(pool_id, id);
`)
	return err
}

func (s *Store) UpsertOnCallReadiness(ctx context.Context, rec OnCallReadiness, allowedKeySHA256 string) (OnCallReadiness, error) {
	if s == nil || s.db == nil {
		return OnCallReadiness{}, ErrStoreClosed
	}
	rec = normalizeOnCallReadiness(rec)
	now := time.Now().UTC()
	if err := validateOnCallReadiness(rec, allowedKeySHA256, now); err != nil {
		return OnCallReadiness{}, err
	}
	rec.UpdatedAtUTC = now
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if existing, ok, err := onCallReadinessByOperationID(ctx, conn, rec.OperationID); err != nil {
			return err
		} else if ok {
			if onCallReadinessMatchesOperation(existing, rec) {
				rec = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		if used, err := operationIDExists(ctx, conn, rec.OperationID); err != nil {
			return err
		} else if used {
			return ErrConflictingOperationID
		}
		current, err := onCallReadinessFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if existing, ok := current[rec.LaunchEnvironmentID]; ok && sameOnCallReadinessExceptRevision(existing, rec) {
			if existing.OperationID == rec.OperationID {
				rec = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		rec.RecordRevision = current[rec.LaunchEnvironmentID].RecordRevision + 1
		if _, err := conn.ExecContext(ctx, `
INSERT INTO trustpool_oncall_readiness_history (
    operation_id, launch_environment_id, record_version, primary_operator_contact, secondary_operator_contact,
    break_glass_escalation_path, compromise_notification_channel, creator_agreement_notification_ack,
    creator_emergency_notification_mechanism, last_confirmed_at_utc, confirmation_ttl_seconds,
    operations_authority_public_key, operations_authority_signature, record_revision, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			rec.OperationID,
			rec.LaunchEnvironmentID,
			rec.RecordVersion,
			rec.PrimaryOperatorContact,
			rec.SecondaryOperatorContact,
			rec.BreakGlassEscalationPath,
			rec.CompromiseNotificationChannel,
			rec.CreatorAgreementNotificationAck,
			rec.CreatorEmergencyNotificationMechanism,
			rec.LastConfirmedAtUTC.Format(time.RFC3339Nano),
			rec.ConfirmationTTLSeconds,
			rec.OperationsAuthorityPublicKey,
			rec.OperationsAuthoritySignature,
			rec.RecordRevision,
			rec.UpdatedAtUTC.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO trustpool_oncall_readiness (
    launch_environment_id, operation_id, record_version, primary_operator_contact, secondary_operator_contact,
    break_glass_escalation_path, compromise_notification_channel, creator_agreement_notification_ack,
    creator_emergency_notification_mechanism, last_confirmed_at_utc, confirmation_ttl_seconds,
    operations_authority_public_key, operations_authority_signature, record_revision, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(launch_environment_id) DO UPDATE SET
    operation_id=excluded.operation_id,
    record_version=excluded.record_version,
    primary_operator_contact=excluded.primary_operator_contact,
    secondary_operator_contact=excluded.secondary_operator_contact,
    break_glass_escalation_path=excluded.break_glass_escalation_path,
    compromise_notification_channel=excluded.compromise_notification_channel,
    creator_agreement_notification_ack=excluded.creator_agreement_notification_ack,
    creator_emergency_notification_mechanism=excluded.creator_emergency_notification_mechanism,
    last_confirmed_at_utc=excluded.last_confirmed_at_utc,
    confirmation_ttl_seconds=excluded.confirmation_ttl_seconds,
    operations_authority_public_key=excluded.operations_authority_public_key,
    operations_authority_signature=excluded.operations_authority_signature,
    record_revision=excluded.record_revision,
    updated_at_utc=excluded.updated_at_utc
`,
			rec.LaunchEnvironmentID,
			rec.OperationID,
			rec.RecordVersion,
			rec.PrimaryOperatorContact,
			rec.SecondaryOperatorContact,
			rec.BreakGlassEscalationPath,
			rec.CompromiseNotificationChannel,
			rec.CreatorAgreementNotificationAck,
			rec.CreatorEmergencyNotificationMechanism,
			rec.LastConfirmedAtUTC.Format(time.RFC3339Nano),
			rec.ConfirmationTTLSeconds,
			rec.OperationsAuthorityPublicKey,
			rec.OperationsAuthoritySignature,
			rec.RecordRevision,
			rec.UpdatedAtUTC.Format(time.RFC3339Nano),
		)
		return err
	})
	if err != nil {
		return OnCallReadiness{}, err
	}
	return rec, nil
}

// RequireOnCallReadinessForPromotion fail-closes operator HTTP production
// promote when the reconstructed pool is non-candidate and the matching
// on-call row is missing or expired. Candidate pools skip this check so the
// isolated-candidate journey stays valid. Missing pools and pools without a
// root issuer are left to PromotePool preconditions. This is not inside the
// PromotePool transaction.
func (s *Store) RequireOnCallReadinessForPromotion(ctx context.Context, poolID string) error {
	poolID = strings.TrimSpace(poolID)
	if poolID == "" {
		return nil
	}
	state, err := s.Reconstruct(ctx)
	if err != nil {
		return err
	}
	if state == nil {
		return nil
	}
	p := state.Pools[poolID]
	if p == nil || p.RootIssuer == nil {
		return nil
	}
	environment := strings.TrimSpace(p.RootIssuer.LaunchEnvironment)
	if environment == "" || environment == promotionLaunchEnvironmentCandidate {
		return nil
	}
	rec, ok, err := s.OnCallReadiness(ctx, environment)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%w: production promotion requires current on-call readiness for %s", ErrOnCallReadiness, environment)
	}
	if rec.Expired(time.Now().UTC()) {
		return fmt.Errorf("%w: on-call readiness expired for %s", ErrOnCallReadiness, environment)
	}
	return nil
}

func (s *Store) OnCallReadiness(ctx context.Context, launchEnvironmentID string) (OnCallReadiness, bool, error) {
	if s == nil || s.db == nil {
		return OnCallReadiness{}, false, ErrStoreClosed
	}
	var rec OnCallReadiness
	var found bool
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		current, err := onCallReadinessFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		rec, found = current[strings.TrimSpace(launchEnvironmentID)]
		return nil
	})
	return rec, found, err
}

func onCallReadinessFromQueryer(ctx context.Context, q eventQueryer) (map[string]OnCallReadiness, error) {
	rows, err := q.QueryContext(ctx, `
SELECT operation_id, launch_environment_id, record_version, primary_operator_contact, secondary_operator_contact,
       break_glass_escalation_path, compromise_notification_channel, creator_agreement_notification_ack,
       creator_emergency_notification_mechanism, last_confirmed_at_utc, confirmation_ttl_seconds,
       operations_authority_public_key, operations_authority_signature, record_revision, updated_at_utc
FROM trustpool_oncall_readiness`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]OnCallReadiness{}
	for rows.Next() {
		rec, err := scanOnCallReadiness(rows)
		if err != nil {
			return nil, err
		}
		out[rec.LaunchEnvironmentID] = rec
	}
	return out, rows.Err()
}

func onCallReadinessByOperationID(ctx context.Context, q eventQueryer, operationID string) (OnCallReadiness, bool, error) {
	rows, err := q.QueryContext(ctx, `
SELECT operation_id, launch_environment_id, record_version, primary_operator_contact, secondary_operator_contact,
       break_glass_escalation_path, compromise_notification_channel, creator_agreement_notification_ack,
       creator_emergency_notification_mechanism, last_confirmed_at_utc, confirmation_ttl_seconds,
       operations_authority_public_key, operations_authority_signature, record_revision, updated_at_utc
FROM trustpool_oncall_readiness_history WHERE operation_id = ? LIMIT 1`, operationID)
	if err != nil {
		return OnCallReadiness{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return OnCallReadiness{}, false, rows.Err()
	}
	rec, err := scanOnCallReadiness(rows)
	return rec, err == nil, err
}

type onCallScanner interface {
	Scan(dest ...any) error
}

func scanOnCallReadiness(row onCallScanner) (OnCallReadiness, error) {
	var rec OnCallReadiness
	var lastConfirmed, updated string
	if err := row.Scan(
		&rec.OperationID,
		&rec.LaunchEnvironmentID,
		&rec.RecordVersion,
		&rec.PrimaryOperatorContact,
		&rec.SecondaryOperatorContact,
		&rec.BreakGlassEscalationPath,
		&rec.CompromiseNotificationChannel,
		&rec.CreatorAgreementNotificationAck,
		&rec.CreatorEmergencyNotificationMechanism,
		&lastConfirmed,
		&rec.ConfirmationTTLSeconds,
		&rec.OperationsAuthorityPublicKey,
		&rec.OperationsAuthoritySignature,
		&rec.RecordRevision,
		&updated,
	); err != nil {
		return OnCallReadiness{}, err
	}
	var err error
	rec.LastConfirmedAtUTC, err = time.Parse(time.RFC3339Nano, lastConfirmed)
	if err != nil {
		return OnCallReadiness{}, err
	}
	rec.UpdatedAtUTC, err = time.Parse(time.RFC3339Nano, updated)
	if err != nil {
		return OnCallReadiness{}, err
	}
	rec.ConfirmationTTL = time.Duration(rec.ConfirmationTTLSeconds) * time.Second
	return rec, nil
}

func onCallReadinessMatchesOperation(existing, incoming OnCallReadiness) bool {
	incoming.RecordRevision = existing.RecordRevision
	incoming.UpdatedAtUTC = existing.UpdatedAtUTC
	return sameOnCallReadinessExceptRevision(existing, incoming) && existing.OperationID == incoming.OperationID
}

func sameOnCallReadinessExceptRevision(a, b OnCallReadiness) bool {
	return a.LaunchEnvironmentID == b.LaunchEnvironmentID &&
		a.RecordVersion == b.RecordVersion &&
		a.PrimaryOperatorContact == b.PrimaryOperatorContact &&
		a.SecondaryOperatorContact == b.SecondaryOperatorContact &&
		a.BreakGlassEscalationPath == b.BreakGlassEscalationPath &&
		a.CompromiseNotificationChannel == b.CompromiseNotificationChannel &&
		a.CreatorAgreementNotificationAck == b.CreatorAgreementNotificationAck &&
		a.CreatorEmergencyNotificationMechanism == b.CreatorEmergencyNotificationMechanism &&
		a.LastConfirmedAtUTC.Equal(b.LastConfirmedAtUTC) &&
		a.ConfirmationTTLSeconds == b.ConfirmationTTLSeconds &&
		a.OperationsAuthorityPublicKey == b.OperationsAuthorityPublicKey &&
		a.OperationsAuthoritySignature == b.OperationsAuthoritySignature
}
