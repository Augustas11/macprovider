package trustpool

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
)

const (
	EventPoolCreated          = "pool_created"
	EventRootIssuerRegistered = "root_issuer_registered"
	EventManifestAccepted     = "manifest_accepted"
	EventLifecycleChanged     = "lifecycle_changed"
	EventMemberAdmitted       = "member_admitted"
	EventMemberRevoked        = "member_revoked"
	EventBuyerAuthorized      = "buyer_authorized"
	EventBuyerAuthorizationRm = "buyer_authorization_removed"
	EventMinBinaryVersionSet  = "min_binary_version_set"

	LifecycleCreated  = "created"
	LifecycleActive   = "active"
	LifecyclePaused   = "paused"
	LifecycleDraining = "draining"
	LifecycleRetired  = "retired"
)

var (
	ErrStoreClosed                 = errors.New("trustpool: store is closed")
	ErrConflictingOperationID      = errors.New("trustpool: conflicting operation id")
	ErrMalformedDurableEvent       = errors.New("trustpool: malformed durable event history")
	ErrActivationRequiresPromotion = errors.New("trustpool: active lifecycle requires promotion gate")
	ErrRootRegistrationNonce       = errors.New("trustpool: invalid root registration nonce")
	ErrCreatorApprovalGate         = errors.New("trustpool: creator approval gate failed")
)

// DurableEvent is one append-only SPEC-043 pool control-plane fact. It records
// enough to rebuild routeable pool membership, lifecycle, creator ownership for
// accepted pools, buyer scopes, creator root registration, and signed manifest
// labels. Creator approval itself is durable coordinator state layered beside
// the append-only event ledger so suspension can affect routeability without
// appending a pool event.
type DurableEvent struct {
	OperationID        string    `json:"operation_id"`
	TimestampUTC       time.Time `json:"timestamp_utc"`
	EventType          string    `json:"event_type"`
	PoolID             string    `json:"pool_id"`
	CreatorAccountID   string    `json:"creator_account_id,omitempty"`
	ApprovalRecordID   string    `json:"approval_record_id,omitempty"`
	ProviderID         string    `json:"provider_id,omitempty"`
	BuyerAccountID     string    `json:"buyer_account_id,omitempty"`
	Lifecycle          string    `json:"lifecycle,omitempty"`
	Reason             string    `json:"reason,omitempty"`
	MinBinaryVersion   string    `json:"min_binary_version,omitempty"`
	ManifestVersion    uint64    `json:"manifest_version,omitempty"`
	ManifestCoreDigest string    `json:"manifest_core_digest,omitempty"`
	ManifestSignature  string    `json:"manifest_signature,omitempty"`
	ManifestSnapshot   string    `json:"manifest_snapshot,omitempty"`

	CurrentApprovalVersion             string `json:"current_approval_version,omitempty"`
	RootIssuerKeyID                    string `json:"root_issuer_key_id,omitempty"`
	RootIssuerPublicKeyDER             string `json:"root_issuer_public_key_der,omitempty"`
	RootIssuerPublicKeyFingerprint     string `json:"root_issuer_public_key_fingerprint,omitempty"`
	RootSignatureAlgorithm             string `json:"root_signature_algorithm,omitempty"`
	ManifestAuthorityRootKeyID         string `json:"manifest_authority_root_key_id,omitempty"`
	ManifestAuthorityRootPublicKey     string `json:"manifest_authority_root_public_key,omitempty"`
	RootRegistrationSignature          string `json:"proof_of_possession_signature,omitempty"`
	StructuredKeyCustodyDisclosureHash string `json:"structured_key_custody_disclosure_hash,omitempty"`
	GenesisNonceDigest                 string `json:"genesis_nonce_digest,omitempty"`
	IntendedPoolDisplayNameHash        string `json:"intended_pool_display_name_hash,omitempty"`
	LaunchEnvironment                  string `json:"launch_environment,omitempty"`
	RootRegistrationNonce              string `json:"nonce,omitempty"`
	RootRegistrationNonceExpiry        string `json:"nonce_expiry,omitempty"`
	RootRegistrationPurpose            string `json:"purpose,omitempty"`
	RootRegistrationEnvironment        string `json:"environment,omitempty"`
}

// Store persists DurableEvent rows in the coordinator SQLite DB.
type Store struct {
	db *sql.DB
}

const (
	CreatorStatusEnabled   = "enabled"
	CreatorStatusSuspended = "suspended"
)

type CreatorApproval struct {
	CreatorAccountID                  string    `json:"creator_account_id"`
	ApprovalRecordID                  string    `json:"approval_record_id"`
	CurrentApprovalVersion            string    `json:"current_approval_version"`
	PublicDisplayName                 string    `json:"public_display_name"`
	LegalSupportContact               string    `json:"legal_support_contact"`
	BillingContact                    string    `json:"billing_contact"`
	EmergencyNotificationEndpoint     string    `json:"emergency_notification_endpoint"`
	AcknowledgedMaxResponseTime       string    `json:"acknowledged_max_response_time"`
	AllowedProductCategory            string    `json:"allowed_product_category"`
	DataRetentionCategory             string    `json:"data_retention_category"`
	SupportOwner                      string    `json:"support_owner"`
	AllowedLaunchEnvironment          string    `json:"allowed_launch_environment"`
	CreatorAgreementID                string    `json:"creator_agreement_id"`
	CreatorAgreementVersion           string    `json:"creator_agreement_version"`
	CreatorAgreementExpiresAtUTC      time.Time `json:"creator_agreement_expires_at_utc"`
	CreatorAgreementGraceEndsAtUTC    time.Time `json:"creator_agreement_grace_ends_at_utc"`
	PricingScheduleID                 string    `json:"pricing_schedule_id"`
	PricingScheduleVersion            string    `json:"pricing_schedule_version"`
	ProhibitedClaimAcknowledgmentHash string    `json:"prohibited_claim_acknowledgment_hash"`
	BuyerDisclosureCommitmentHash     string    `json:"buyer_disclosure_commitment_hash"`
	ApprovalCriteriaHash              string    `json:"approval_criteria_hash"`
	ApprovedBy                        string    `json:"approved_by"`
	ApprovedAtUTC                     time.Time `json:"approved_at_utc"`
	ApprovalRevision                  uint64    `json:"approval_revision"`
	Status                            string    `json:"status"`
	SuspensionReason                  string    `json:"suspension_reason,omitempty"`
	UpdatedAtUTC                      time.Time `json:"updated_at_utc"`
}

func NewStore(db *sql.DB) (*Store, error) {
	if db == nil {
		return nil, ErrStoreClosed
	}
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	if s == nil || s.db == nil {
		return ErrStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS trustpool_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id TEXT NOT NULL UNIQUE,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    pool_id TEXT NOT NULL,
    creator_account_id TEXT,
    approval_record_id TEXT,
    provider_id TEXT,
    buyer_account_id TEXT,
    lifecycle TEXT,
    min_binary_version TEXT,
    manifest_version INTEGER NOT NULL DEFAULT 0,
    manifest_core_digest TEXT,
    root_issuer_key_id TEXT,
    root_issuer_public_key_fingerprint TEXT,
    launch_environment TEXT,
    current_approval_version TEXT,
    reason TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trustpool_events_pool_id ON trustpool_events(pool_id, id);
CREATE INDEX IF NOT EXISTS idx_trustpool_events_creator ON trustpool_events(creator_account_id, id);
CREATE INDEX IF NOT EXISTS idx_trustpool_events_event_type ON trustpool_events(event_type, id);
CREATE TABLE IF NOT EXISTS trustpool_root_registration_nonces (
    nonce TEXT PRIMARY KEY,
    creator_account_id TEXT NOT NULL,
    approval_record_id TEXT NOT NULL,
    current_approval_version TEXT NOT NULL,
    launch_environment TEXT NOT NULL,
    purpose TEXT NOT NULL,
    expires_at_utc TEXT NOT NULL,
    issued_at_utc TEXT NOT NULL,
    consumed_operation_id TEXT,
    consumed_at_utc TEXT
);
CREATE INDEX IF NOT EXISTS idx_trustpool_root_registration_nonces_creator ON trustpool_root_registration_nonces(creator_account_id, issued_at_utc);
CREATE TABLE IF NOT EXISTS trustpool_creator_approvals (
    creator_account_id TEXT PRIMARY KEY,
    approval_record_id TEXT NOT NULL,
    current_approval_version TEXT NOT NULL,
    public_display_name TEXT NOT NULL,
    legal_support_contact TEXT NOT NULL,
    billing_contact TEXT NOT NULL,
    emergency_notification_endpoint TEXT NOT NULL,
    acknowledged_max_response_time TEXT NOT NULL,
    allowed_product_category TEXT NOT NULL,
    data_retention_category TEXT NOT NULL,
    support_owner TEXT NOT NULL,
    allowed_launch_environment TEXT NOT NULL,
    creator_agreement_id TEXT NOT NULL,
    creator_agreement_version TEXT NOT NULL,
    creator_agreement_expires_at_utc TEXT NOT NULL,
    creator_agreement_grace_ends_at_utc TEXT NOT NULL,
    pricing_schedule_id TEXT NOT NULL,
    pricing_schedule_version TEXT NOT NULL,
    prohibited_claim_acknowledgment_hash TEXT NOT NULL,
    buyer_disclosure_commitment_hash TEXT NOT NULL,
    approval_criteria_hash TEXT NOT NULL,
    approved_by TEXT NOT NULL,
    approved_at_utc TEXT NOT NULL,
    approval_revision INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL,
    suspension_reason TEXT,
    updated_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trustpool_creator_approvals_status ON trustpool_creator_approvals(status, updated_at_utc);
`)
	if err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "trustpool_creator_approvals", "approval_revision", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "trustpool_creator_approvals", "acknowledged_max_response_time", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "trustpool_creator_approvals", "data_retention_category", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "trustpool_events", "approval_record_id", "TEXT"); err != nil {
		return err
	}
	for _, c := range []struct {
		name string
		decl string
	}{
		{name: "root_issuer_key_id", decl: "TEXT"},
		{name: "root_issuer_public_key_fingerprint", decl: "TEXT"},
		{name: "launch_environment", decl: "TEXT"},
		{name: "current_approval_version", decl: "TEXT"},
	} {
		if err := s.ensureColumn(ctx, "trustpool_events", c.name, c.decl); err != nil {
			return err
		}
	}
	if _, err := s.db.ExecContext(ctx, `CREATE INDEX IF NOT EXISTS idx_trustpool_events_approval ON trustpool_events(approval_record_id, id)`); err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `CREATE INDEX IF NOT EXISTS idx_trustpool_events_root_fingerprint ON trustpool_events(root_issuer_public_key_fingerprint, id)`)
	return err
}

type RootRegistrationNonceIssue struct {
	CreatorAccountID       string
	ApprovalRecordID       string
	CurrentApprovalVersion string
	LaunchEnvironment      string
	Purpose                string
	ExpiresAtUTC           time.Time
}

type RootRegistrationNonceRecord struct {
	Nonce                  string
	CreatorAccountID       string
	ApprovalRecordID       string
	CurrentApprovalVersion string
	LaunchEnvironment      string
	Purpose                string
	ExpiresAtUTC           time.Time
	IssuedAtUTC            time.Time
}

func (s *Store) UpsertCreatorApproval(ctx context.Context, approval CreatorApproval) (CreatorApproval, error) {
	if s == nil || s.db == nil {
		return CreatorApproval{}, ErrStoreClosed
	}
	approval = normalizeCreatorApproval(approval)
	if err := validateCreatorApproval(approval); err != nil {
		return CreatorApproval{}, err
	}
	now := time.Now().UTC()
	approval.UpdatedAtUTC = now
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		currentApprovals, err := creatorApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if current, ok := currentApprovals[approval.CreatorAccountID]; ok && sameCreatorApprovalExceptRevision(current, approval) {
			approval = current
			return nil
		}
		if err := validateCreatorReactivation(ctx, conn, currentApprovals, approval, now); err != nil {
			return err
		}
		approval.ApprovalRevision = currentApprovals[approval.CreatorAccountID].ApprovalRevision + 1
		if _, err := conn.ExecContext(ctx, `
INSERT INTO trustpool_creator_approvals (
    creator_account_id, approval_record_id, current_approval_version,
    public_display_name, legal_support_contact, billing_contact, emergency_notification_endpoint,
    acknowledged_max_response_time, allowed_product_category, data_retention_category,
    support_owner, allowed_launch_environment,
    creator_agreement_id, creator_agreement_version, creator_agreement_expires_at_utc,
    creator_agreement_grace_ends_at_utc, pricing_schedule_id, pricing_schedule_version,
    prohibited_claim_acknowledgment_hash, buyer_disclosure_commitment_hash, approval_criteria_hash,
    approved_by, approved_at_utc, approval_revision, status, suspension_reason, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(creator_account_id) DO UPDATE SET
    approval_record_id = excluded.approval_record_id,
    current_approval_version = excluded.current_approval_version,
    public_display_name = excluded.public_display_name,
    legal_support_contact = excluded.legal_support_contact,
    billing_contact = excluded.billing_contact,
    emergency_notification_endpoint = excluded.emergency_notification_endpoint,
    acknowledged_max_response_time = excluded.acknowledged_max_response_time,
    allowed_product_category = excluded.allowed_product_category,
    data_retention_category = excluded.data_retention_category,
    support_owner = excluded.support_owner,
    allowed_launch_environment = excluded.allowed_launch_environment,
    creator_agreement_id = excluded.creator_agreement_id,
    creator_agreement_version = excluded.creator_agreement_version,
    creator_agreement_expires_at_utc = excluded.creator_agreement_expires_at_utc,
    creator_agreement_grace_ends_at_utc = excluded.creator_agreement_grace_ends_at_utc,
    pricing_schedule_id = excluded.pricing_schedule_id,
    pricing_schedule_version = excluded.pricing_schedule_version,
    prohibited_claim_acknowledgment_hash = excluded.prohibited_claim_acknowledgment_hash,
    buyer_disclosure_commitment_hash = excluded.buyer_disclosure_commitment_hash,
    approval_criteria_hash = excluded.approval_criteria_hash,
    approved_by = excluded.approved_by,
    approved_at_utc = excluded.approved_at_utc,
    approval_revision = excluded.approval_revision,
    status = excluded.status,
    suspension_reason = excluded.suspension_reason,
    updated_at_utc = excluded.updated_at_utc`,
			approval.CreatorAccountID,
			approval.ApprovalRecordID,
			approval.CurrentApprovalVersion,
			nullString(approval.PublicDisplayName),
			nullString(approval.LegalSupportContact),
			nullString(approval.BillingContact),
			nullString(approval.EmergencyNotificationEndpoint),
			approval.AcknowledgedMaxResponseTime,
			nullString(approval.AllowedProductCategory),
			approval.DataRetentionCategory,
			nullString(approval.SupportOwner),
			approval.AllowedLaunchEnvironment,
			approval.CreatorAgreementID,
			approval.CreatorAgreementVersion,
			approval.CreatorAgreementExpiresAtUTC.Format(time.RFC3339Nano),
			approval.CreatorAgreementGraceEndsAtUTC.Format(time.RFC3339Nano),
			nullString(approval.PricingScheduleID),
			nullString(approval.PricingScheduleVersion),
			approval.ProhibitedClaimAcknowledgmentHash,
			approval.BuyerDisclosureCommitmentHash,
			approval.ApprovalCriteriaHash,
			approval.ApprovedBy,
			approval.ApprovedAtUTC.Format(time.RFC3339Nano),
			approval.ApprovalRevision,
			approval.Status,
			nullString(approval.SuspensionReason),
			approval.UpdatedAtUTC.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		if approval.Status == CreatorStatusSuspended {
			return invalidateCreatorPendingRootNonces(ctx, conn, approval)
		}
		return nil
	})
	if err != nil {
		return CreatorApproval{}, err
	}
	return approval, nil
}

func validateCreatorReactivation(ctx context.Context, conn *sql.Conn, currentApprovals map[string]CreatorApproval, next CreatorApproval, now time.Time) error {
	current, existed := currentApprovals[next.CreatorAccountID]
	if !existed {
		return nil
	}
	events, err := eventsFromQueryer(ctx, conn)
	if err != nil {
		return err
	}
	currentState, err := reconstructEventsWithApprovals(events, currentApprovals, now)
	if err != nil {
		return err
	}
	for _, p := range currentState.Pools {
		if p.CreatorAccountID != next.CreatorAccountID || p.Lifecycle != LifecycleActive || p.RootIssuer == nil {
			continue
		}
		if current.ValidFor(p.ApprovalRecordID, p.RootIssuer.CurrentApprovalVersion, p.RootIssuer.LaunchEnvironment, now) {
			continue
		}
		if next.ValidFor(p.ApprovalRecordID, p.RootIssuer.CurrentApprovalVersion, p.RootIssuer.LaunchEnvironment, now) {
			return ErrCreatorApprovalGate
		}
	}
	return nil
}

func invalidateCreatorPendingRootNonces(ctx context.Context, conn *sql.Conn, approval CreatorApproval) error {
	invalidatedOperationID := fmt.Sprintf("creator_approval_suspended:%s:%d", approval.CreatorAccountID, approval.ApprovalRevision)
	_, err := conn.ExecContext(ctx, `
UPDATE trustpool_root_registration_nonces
SET consumed_operation_id = ?, consumed_at_utc = ?
WHERE creator_account_id = ? AND consumed_operation_id IS NULL`,
		invalidatedOperationID,
		approval.UpdatedAtUTC.Format(time.RFC3339Nano),
		approval.CreatorAccountID,
	)
	return err
}

func (s *Store) CreatorApproval(ctx context.Context, creatorAccountID string) (CreatorApproval, bool, error) {
	if s == nil || s.db == nil {
		return CreatorApproval{}, false, ErrStoreClosed
	}
	return creatorApprovalFromQueryer(ctx, s.db, strings.TrimSpace(creatorAccountID))
}

func (s *Store) creatorApprovals(ctx context.Context) (map[string]CreatorApproval, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	return creatorApprovalsFromQueryer(ctx, s.db)
}

func (s *Store) IssueRootRegistrationNonce(ctx context.Context, issue RootRegistrationNonceIssue) (RootRegistrationNonceRecord, error) {
	if s == nil || s.db == nil {
		return RootRegistrationNonceRecord{}, ErrStoreClosed
	}
	issue.CreatorAccountID = strings.TrimSpace(issue.CreatorAccountID)
	issue.ApprovalRecordID = strings.TrimSpace(issue.ApprovalRecordID)
	issue.CurrentApprovalVersion = strings.TrimSpace(issue.CurrentApprovalVersion)
	issue.LaunchEnvironment = strings.TrimSpace(issue.LaunchEnvironment)
	issue.Purpose = strings.TrimSpace(issue.Purpose)
	if issue.Purpose == "" {
		issue.Purpose = RootRegistrationPurposeDefault
	}
	if issue.CreatorAccountID == "" || issue.ApprovalRecordID == "" || issue.CurrentApprovalVersion == "" ||
		issue.LaunchEnvironment == "" || issue.Purpose != RootRegistrationPurposeDefault || issue.ExpiresAtUTC.IsZero() {
		return RootRegistrationNonceRecord{}, ErrRootRegistrationNonce
	}
	now := time.Now().UTC()
	expires := issue.ExpiresAtUTC.UTC()
	if !now.Before(expires) {
		return RootRegistrationNonceRecord{}, ErrRootRegistrationNonce
	}
	var nonceBytes [32]byte
	if _, err := rand.Read(nonceBytes[:]); err != nil {
		return RootRegistrationNonceRecord{}, err
	}
	record := RootRegistrationNonceRecord{
		Nonce:                  base64.RawURLEncoding.EncodeToString(nonceBytes[:]),
		CreatorAccountID:       issue.CreatorAccountID,
		ApprovalRecordID:       issue.ApprovalRecordID,
		CurrentApprovalVersion: issue.CurrentApprovalVersion,
		LaunchEnvironment:      issue.LaunchEnvironment,
		Purpose:                issue.Purpose,
		ExpiresAtUTC:           expires,
		IssuedAtUTC:            now,
	}
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		approval, ok, err := creatorApprovalFromQueryer(ctx, conn, issue.CreatorAccountID)
		if err != nil {
			return err
		}
		if !ok || !approval.ValidFor(issue.ApprovalRecordID, issue.CurrentApprovalVersion, issue.LaunchEnvironment, now) {
			return ErrCreatorApprovalGate
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO trustpool_root_registration_nonces (
    nonce, creator_account_id, approval_record_id, current_approval_version,
    launch_environment, purpose, expires_at_utc, issued_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			record.Nonce,
			record.CreatorAccountID,
			record.ApprovalRecordID,
			record.CurrentApprovalVersion,
			record.LaunchEnvironment,
			record.Purpose,
			record.ExpiresAtUTC.Format(time.RFC3339Nano),
			record.IssuedAtUTC.Format(time.RFC3339Nano),
		)
		return err
	})
	if err != nil {
		return RootRegistrationNonceRecord{}, err
	}
	return record, nil
}

func (s *Store) ensureColumn(ctx context.Context, table, column, decl string) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name string
		var typ string
		var notNull int
		var defaultValue any
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == column {
			return rows.Err()
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE `+table+` ADD COLUMN `+column+` `+decl)
	return err
}

// appendEventUnchecked appends an idempotent control-plane event after only
// per-event validation. Production control-plane callers must use
// AppendValidatedEvent so a mutation cannot poison future boot replay.
func (s *Store) appendEventUnchecked(ctx context.Context, e DurableEvent) error {
	if s == nil || s.db == nil {
		return ErrStoreClosed
	}
	e.TimestampUTC = e.TimestampUTC.UTC()
	if err := validateEvent(e); err != nil {
		return err
	}
	payload, err := json.Marshal(e)
	if err != nil {
		return err
	}
	var existing string
	err = s.db.QueryRowContext(ctx, `SELECT payload_json FROM trustpool_events WHERE operation_id = ?`, e.OperationID).Scan(&existing)
	switch {
	case err == nil && existing == string(payload):
		return nil
	case err == nil:
		return ErrConflictingOperationID
	case !errors.Is(err, sql.ErrNoRows):
		return err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO trustpool_events (
	    operation_id, ts_utc, event_type, pool_id, creator_account_id, approval_record_id, provider_id,
	    buyer_account_id, lifecycle, min_binary_version, manifest_version,
	    manifest_core_digest, root_issuer_key_id, root_issuer_public_key_fingerprint,
	    launch_environment, current_approval_version, reason, payload_json
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.OperationID,
		e.TimestampUTC.Format(time.RFC3339Nano),
		e.EventType,
		e.PoolID,
		nullString(e.CreatorAccountID),
		nullString(e.ApprovalRecordID),
		nullString(e.ProviderID),
		nullString(e.BuyerAccountID),
		nullString(e.Lifecycle),
		nullString(e.MinBinaryVersion),
		e.ManifestVersion,
		nullString(e.ManifestCoreDigest),
		nullString(e.RootIssuerKeyID),
		nullString(e.RootIssuerPublicKeyFingerprint),
		nullString(e.LaunchEnvironment),
		nullString(e.CurrentApprovalVersion),
		nullString(e.Reason),
		string(payload),
	)
	if err != nil {
		if replayErr := s.classifyDuplicate(ctx, e.OperationID, string(payload)); replayErr == nil || errors.Is(replayErr, ErrConflictingOperationID) {
			return replayErr
		}
		return err
	}
	return nil
}

func (s *Store) classifyDuplicate(ctx context.Context, operationID, payload string) error {
	var existing string
	err := s.db.QueryRowContext(ctx, `SELECT payload_json FROM trustpool_events WHERE operation_id = ?`, operationID).Scan(&existing)
	if errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err != nil {
		return err
	}
	if existing == payload {
		return nil
	}
	return ErrConflictingOperationID
}

func (s *Store) Events(ctx context.Context) ([]DurableEvent, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	return eventsFromQueryer(ctx, s.db)
}

// AppendValidatedEvent appends e only if the full durable history still
// reconstructs after the append. This is the candidate/restrictive control-plane
// write primitive for admin/API surfaces: a syntactically valid event must not
// poison future boot replay with an invalid lifecycle or ordering transition,
// and raw active lifecycle publication is reserved for a future promotion gate.
func (s *Store) AppendValidatedEvent(ctx context.Context, e DurableEvent) (*ReconstructedState, DurableEvent, bool, error) {
	if s == nil || s.db == nil {
		return nil, DurableEvent{}, false, ErrStoreClosed
	}
	if e.EventType == EventLifecycleChanged && strings.TrimSpace(e.Lifecycle) == LifecycleActive {
		return nil, DurableEvent{}, false, ErrActivationRequiresPromotion
	}
	timestampProvided := !e.TimestampUTC.IsZero()
	if timestampProvided {
		e.TimestampUTC = e.TimestampUTC.UTC()
	}
	var reconstructed *ReconstructedState
	var committed DurableEvent
	var applied bool
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		events, err := eventsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		approvals, err := creatorApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		for _, existing := range events {
			if existing.OperationID != e.OperationID {
				continue
			}
			if !timestampProvided {
				e.TimestampUTC = existing.TimestampUTC.UTC()
			}
			if err := validateEvent(e); err != nil {
				return err
			}
			payload, err := json.Marshal(e)
			if err != nil {
				return err
			}
			existingPayload, err := json.Marshal(existing)
			if err != nil {
				return err
			}
			if string(existingPayload) != string(payload) {
				return ErrConflictingOperationID
			}
			reconstructed, err = reconstructEventsWithApprovals(events, approvals, time.Now().UTC())
			committed = existing
			applied = false
			return err
		}
		if !timestampProvided {
			e.TimestampUTC = time.Now().UTC()
		}
		if err := validateEvent(e); err != nil {
			return err
		}
		preState, err := reconstructEventsWithApprovals(events, approvals, time.Now().UTC())
		if err != nil {
			return err
		}
		if err := preState.validateMutationCreatorGate(e, time.Now().UTC()); err != nil {
			return err
		}
		if e.EventType == EventRootIssuerRegistered {
			if err := consumeRootRegistrationNonce(ctx, conn, e, time.Now().UTC()); err != nil {
				return err
			}
		}
		payload, err := json.Marshal(e)
		if err != nil {
			return err
		}
		next := append(append([]DurableEvent(nil), events...), e)
		state, err := reconstructEventsWithApprovals(next, approvals, time.Now().UTC())
		if err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
	INSERT INTO trustpool_events (
	    operation_id, ts_utc, event_type, pool_id, creator_account_id, approval_record_id, provider_id,
	    buyer_account_id, lifecycle, min_binary_version, manifest_version,
	    manifest_core_digest, root_issuer_key_id, root_issuer_public_key_fingerprint,
	    launch_environment, current_approval_version, reason, payload_json
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			e.OperationID,
			e.TimestampUTC.Format(time.RFC3339Nano),
			e.EventType,
			e.PoolID,
			nullString(e.CreatorAccountID),
			nullString(e.ApprovalRecordID),
			nullString(e.ProviderID),
			nullString(e.BuyerAccountID),
			nullString(e.Lifecycle),
			nullString(e.MinBinaryVersion),
			e.ManifestVersion,
			nullString(e.ManifestCoreDigest),
			nullString(e.RootIssuerKeyID),
			nullString(e.RootIssuerPublicKeyFingerprint),
			nullString(e.LaunchEnvironment),
			nullString(e.CurrentApprovalVersion),
			nullString(e.Reason),
			string(payload),
		)
		if err != nil {
			return err
		}
		reconstructed = state
		committed = e
		applied = true
		return nil
	})
	if err != nil {
		return nil, DurableEvent{}, false, err
	}
	return reconstructed, committed, applied, nil
}

func consumeRootRegistrationNonce(ctx context.Context, conn *sql.Conn, e DurableEvent, acceptedAt time.Time) error {
	var creatorAccountID, approvalRecordID, currentApprovalVersion, launchEnvironment, purpose, expiresRaw string
	var consumedOperationID sql.NullString
	err := conn.QueryRowContext(ctx, `
SELECT creator_account_id, approval_record_id, current_approval_version, launch_environment,
       purpose, expires_at_utc, consumed_operation_id
FROM trustpool_root_registration_nonces
WHERE nonce = ?`, e.RootRegistrationNonce).Scan(
		&creatorAccountID,
		&approvalRecordID,
		&currentApprovalVersion,
		&launchEnvironment,
		&purpose,
		&expiresRaw,
		&consumedOperationID,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrRootRegistrationNonce
	}
	if err != nil {
		return err
	}
	expiresAt, err := time.Parse(time.RFC3339Nano, expiresRaw)
	if err != nil {
		return ErrRootRegistrationNonce
	}
	if creatorAccountID != e.CreatorAccountID ||
		approvalRecordID != e.ApprovalRecordID ||
		currentApprovalVersion != e.CurrentApprovalVersion ||
		launchEnvironment != e.LaunchEnvironment ||
		purpose != e.RootRegistrationPurpose ||
		e.RootRegistrationEnvironment != e.LaunchEnvironment ||
		e.RootRegistrationNonceExpiry != expiresAt.UTC().Format(time.RFC3339Nano) {
		return ErrRootRegistrationNonce
	}
	if consumedOperationID.Valid {
		return ErrRootRegistrationNonce
	}
	if !acceptedAt.UTC().Before(expiresAt.UTC()) {
		return ErrRootRegistrationNonce
	}
	res, err := conn.ExecContext(ctx, `
UPDATE trustpool_root_registration_nonces
SET consumed_operation_id = ?, consumed_at_utc = ?
WHERE nonce = ? AND consumed_operation_id IS NULL`,
		e.OperationID,
		acceptedAt.UTC().Format(time.RFC3339Nano),
		e.RootRegistrationNonce,
	)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows != 1 {
		return ErrRootRegistrationNonce
	}
	return nil
}

type eventQueryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func eventsFromQueryer(ctx context.Context, q eventQueryer) ([]DurableEvent, error) {
	rows, err := q.QueryContext(ctx, `SELECT id, operation_id, payload_json FROM trustpool_events ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []DurableEvent
	seen := make(map[string]int64)
	for rows.Next() {
		var id int64
		var operationID string
		var raw string
		if err := rows.Scan(&id, &operationID, &raw); err != nil {
			return nil, err
		}
		var e DurableEvent
		if err := json.Unmarshal([]byte(raw), &e); err != nil {
			return nil, err
		}
		if e.OperationID != operationID {
			return nil, fmt.Errorf("%w: row %d operation_id column %q != payload %q", ErrMalformedDurableEvent, id, operationID, e.OperationID)
		}
		if prior, ok := seen[e.OperationID]; ok {
			return nil, fmt.Errorf("%w: operation_id %q appears in rows %d and %d", ErrMalformedDurableEvent, e.OperationID, prior, id)
		}
		seen[e.OperationID] = id
		events = append(events, e)
	}
	return events, rows.Err()
}

func creatorApprovalFromQueryer(ctx context.Context, q eventQueryer, creatorAccountID string) (CreatorApproval, bool, error) {
	if creatorAccountID == "" {
		return CreatorApproval{}, false, nil
	}
	rows, err := q.QueryContext(ctx, `
SELECT creator_account_id, approval_record_id, current_approval_version,
       public_display_name, legal_support_contact, billing_contact, emergency_notification_endpoint,
       acknowledged_max_response_time, allowed_product_category, data_retention_category,
       support_owner, allowed_launch_environment,
       creator_agreement_id, creator_agreement_version, creator_agreement_expires_at_utc,
       creator_agreement_grace_ends_at_utc, pricing_schedule_id, pricing_schedule_version,
       prohibited_claim_acknowledgment_hash, buyer_disclosure_commitment_hash, approval_criteria_hash,
       approved_by, approved_at_utc, approval_revision, status, suspension_reason, updated_at_utc
FROM trustpool_creator_approvals
WHERE creator_account_id = ?`, creatorAccountID)
	if err != nil {
		return CreatorApproval{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return CreatorApproval{}, false, rows.Err()
	}
	approval, err := scanCreatorApproval(rows)
	if err != nil {
		return CreatorApproval{}, false, err
	}
	if rows.Next() {
		return CreatorApproval{}, false, fmt.Errorf("trustpool: duplicate creator approval for %q", creatorAccountID)
	}
	return approval, true, rows.Err()
}

func creatorApprovalsFromQueryer(ctx context.Context, q eventQueryer) (map[string]CreatorApproval, error) {
	rows, err := q.QueryContext(ctx, `
SELECT creator_account_id, approval_record_id, current_approval_version,
       public_display_name, legal_support_contact, billing_contact, emergency_notification_endpoint,
       acknowledged_max_response_time, allowed_product_category, data_retention_category,
       support_owner, allowed_launch_environment,
       creator_agreement_id, creator_agreement_version, creator_agreement_expires_at_utc,
       creator_agreement_grace_ends_at_utc, pricing_schedule_id, pricing_schedule_version,
       prohibited_claim_acknowledgment_hash, buyer_disclosure_commitment_hash, approval_criteria_hash,
       approved_by, approved_at_utc, approval_revision, status, suspension_reason, updated_at_utc
FROM trustpool_creator_approvals`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]CreatorApproval)
	for rows.Next() {
		approval, err := scanCreatorApproval(rows)
		if err != nil {
			return nil, err
		}
		out[approval.CreatorAccountID] = approval
	}
	return out, rows.Err()
}

type creatorApprovalScanner interface {
	Scan(dest ...any) error
}

func scanCreatorApproval(row creatorApprovalScanner) (CreatorApproval, error) {
	var approval CreatorApproval
	var display, legal, billing, emergency, category, supportOwner, pricingID, pricingVersion, suspension sql.NullString
	var expiresRaw, graceRaw, approvedRaw, updatedRaw string
	if err := row.Scan(
		&approval.CreatorAccountID,
		&approval.ApprovalRecordID,
		&approval.CurrentApprovalVersion,
		&display,
		&legal,
		&billing,
		&emergency,
		&approval.AcknowledgedMaxResponseTime,
		&category,
		&approval.DataRetentionCategory,
		&supportOwner,
		&approval.AllowedLaunchEnvironment,
		&approval.CreatorAgreementID,
		&approval.CreatorAgreementVersion,
		&expiresRaw,
		&graceRaw,
		&pricingID,
		&pricingVersion,
		&approval.ProhibitedClaimAcknowledgmentHash,
		&approval.BuyerDisclosureCommitmentHash,
		&approval.ApprovalCriteriaHash,
		&approval.ApprovedBy,
		&approvedRaw,
		&approval.ApprovalRevision,
		&approval.Status,
		&suspension,
		&updatedRaw,
	); err != nil {
		return CreatorApproval{}, err
	}
	var err error
	approval.CreatorAgreementExpiresAtUTC, err = time.Parse(time.RFC3339Nano, expiresRaw)
	if err != nil {
		return CreatorApproval{}, err
	}
	approval.CreatorAgreementGraceEndsAtUTC, err = time.Parse(time.RFC3339Nano, graceRaw)
	if err != nil {
		return CreatorApproval{}, err
	}
	approval.ApprovedAtUTC, err = time.Parse(time.RFC3339Nano, approvedRaw)
	if err != nil {
		return CreatorApproval{}, err
	}
	approval.UpdatedAtUTC, err = time.Parse(time.RFC3339Nano, updatedRaw)
	if err != nil {
		return CreatorApproval{}, err
	}
	approval.PublicDisplayName = display.String
	approval.LegalSupportContact = legal.String
	approval.BillingContact = billing.String
	approval.EmergencyNotificationEndpoint = emergency.String
	approval.AcknowledgedMaxResponseTime = strings.TrimSpace(approval.AcknowledgedMaxResponseTime)
	approval.AllowedProductCategory = category.String
	approval.DataRetentionCategory = strings.TrimSpace(approval.DataRetentionCategory)
	approval.SupportOwner = supportOwner.String
	approval.PricingScheduleID = pricingID.String
	approval.PricingScheduleVersion = pricingVersion.String
	approval.SuspensionReason = suspension.String
	return approval, nil
}

func (s *Store) Reconstruct(ctx context.Context) (*ReconstructedState, error) {
	events, err := s.Events(ctx)
	if err != nil {
		return nil, err
	}
	approvals, err := s.creatorApprovals(ctx)
	if err != nil {
		return nil, err
	}
	return reconstructEventsWithApprovals(events, approvals, time.Now().UTC())
}

// ReconstructedState is the coordinator's query/admin view after durable replay.
type ReconstructedState struct {
	Pools              map[string]*ReconstructedPoolState
	CreatorApprovals   map[string]CreatorApproval
	RouteGateCheckedAt time.Time
	Revision           uint64
	rootNonces         map[string]string
}

type ReconstructedPoolState struct {
	PoolID                  string
	CreatorAccountID        string
	ApprovalRecordID        string
	Lifecycle               string
	LifecycleReason         string
	MinBinaryVersion        string
	ManifestVersion         uint64
	ManifestCoreDigest      string
	RootIssuer              *ReconstructedRootIssuer
	Members                 map[string]bool
	Revoked                 map[string]bool
	BuyerAccounts           map[string]bool
	Generation              uint64
	RouteableGeneration     uint64
	LastEventAtUTC          time.Time
	CreatorGateReason       string
	CreatorGateExpiresAtUTC time.Time
}

type ReconstructedRootIssuer struct {
	KeyID                           string
	PublicKeyDER                    string
	PublicKeyFingerprint            string
	SignatureAlgorithm              string
	CurrentApprovalVersion          string
	ManifestAuthorityRootKeyID      string
	ManifestAuthorityRootPublicKey  string
	StructuredCustodyDisclosureHash string
	GenesisNonceDigest              string
	IntendedPoolDisplayNameHash     string
	LaunchEnvironment               string
	RegistrationNonce               string
	RegistrationNonceExpiry         string
}

func ReconstructEvents(events []DurableEvent) (*ReconstructedState, error) {
	return reconstructEventsWithApprovals(events, nil, time.Time{})
}

func reconstructEventsWithApprovals(events []DurableEvent, approvals map[string]CreatorApproval, gateAt time.Time) (*ReconstructedState, error) {
	state := &ReconstructedState{Pools: make(map[string]*ReconstructedPoolState), rootNonces: make(map[string]string)}
	if approvals != nil {
		state.CreatorApprovals = make(map[string]CreatorApproval, len(approvals))
		for k, v := range approvals {
			state.CreatorApprovals[k] = v
		}
		state.RouteGateCheckedAt = gateAt.UTC()
	}
	seenOps := make(map[string]int)
	for i, e := range events {
		if err := validateEvent(e); err != nil {
			return nil, fmt.Errorf("trustpool: replay event %d: %w", i+1, err)
		}
		if prior, ok := seenOps[e.OperationID]; ok {
			return nil, fmt.Errorf("%w: operation_id %q appears in events %d and %d", ErrMalformedDurableEvent, e.OperationID, prior, i+1)
		}
		seenOps[e.OperationID] = i + 1
		p, err := state.applyEvent(i+1, e)
		if err != nil {
			return nil, err
		}
		p.Generation = uint64(i + 1)
		p.LastEventAtUTC = e.TimestampUTC.UTC()
	}
	state.Revision = routeableRevision(len(events), state.CreatorApprovals)
	state.applyCreatorRouteGates()
	state.rootNonces = nil
	return state, nil
}

func routeableRevision(eventCount int, approvals map[string]CreatorApproval) uint64 {
	revision := uint64(eventCount)
	for _, approval := range approvals {
		revision += approval.ApprovalRevision
	}
	return revision
}

func (s *ReconstructedState) applyEvent(index int, e DurableEvent) (*ReconstructedPoolState, error) {
	p := s.Pools[e.PoolID]
	switch e.EventType {
	case EventPoolCreated:
		if p != nil {
			return nil, fmt.Errorf("%w: event %d duplicate pool_created for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		p = s.ensurePool(e.PoolID)
		p.CreatorAccountID = e.CreatorAccountID
		p.ApprovalRecordID = e.ApprovalRecordID
		return p, nil
	}
	if p == nil {
		return nil, fmt.Errorf("%w: event %d %s before pool_created for pool %q", ErrMalformedDurableEvent, index, e.EventType, e.PoolID)
	}
	if p.Lifecycle == LifecycleRetired {
		return nil, fmt.Errorf("%w: event %d %s after retired pool %q", ErrMalformedDurableEvent, index, e.EventType, e.PoolID)
	}
	switch e.EventType {
	case EventRootIssuerRegistered:
		if p.RootIssuer != nil {
			return nil, fmt.Errorf("%w: event %d duplicate root_issuer_registered for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if priorPool, ok := s.rootNonces[e.RootRegistrationNonce]; ok {
			return nil, fmt.Errorf("%w: event %d root registration nonce reused by pools %q and %q", ErrMalformedDurableEvent, index, priorPool, e.PoolID)
		}
		if p.ManifestVersion != 0 {
			return nil, fmt.Errorf("%w: event %d root_issuer_registered after manifest_accepted for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if e.CreatorAccountID != p.CreatorAccountID || e.ApprovalRecordID != p.ApprovalRecordID {
			return nil, fmt.Errorf("%w: event %d root registration creator approval mismatch for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if priorPool, ok := s.rootFingerprintOwner(e.RootIssuerPublicKeyFingerprint); ok && priorPool != e.PoolID {
			return nil, fmt.Errorf("%w: event %d root fingerprint reused by pools %q and %q", ErrMalformedDurableEvent, index, priorPool, e.PoolID)
		}
		if err := VerifyRootIssuerRegistrationEvent(e); err != nil {
			return nil, fmt.Errorf("%w: event %d root registration invalid: %v", ErrMalformedDurableEvent, index, err)
		}
		p.RootIssuer = &ReconstructedRootIssuer{
			KeyID:                           e.RootIssuerKeyID,
			PublicKeyDER:                    e.RootIssuerPublicKeyDER,
			PublicKeyFingerprint:            e.RootIssuerPublicKeyFingerprint,
			SignatureAlgorithm:              e.RootSignatureAlgorithm,
			CurrentApprovalVersion:          e.CurrentApprovalVersion,
			ManifestAuthorityRootKeyID:      e.ManifestAuthorityRootKeyID,
			ManifestAuthorityRootPublicKey:  e.ManifestAuthorityRootPublicKey,
			StructuredCustodyDisclosureHash: e.StructuredKeyCustodyDisclosureHash,
			GenesisNonceDigest:              e.GenesisNonceDigest,
			IntendedPoolDisplayNameHash:     e.IntendedPoolDisplayNameHash,
			LaunchEnvironment:               e.LaunchEnvironment,
			RegistrationNonce:               e.RootRegistrationNonce,
			RegistrationNonceExpiry:         e.RootRegistrationNonceExpiry,
		}
		s.rootNonces[e.RootRegistrationNonce] = e.PoolID
	case EventManifestAccepted:
		if p.RootIssuer == nil {
			return nil, fmt.Errorf("%w: event %d manifest_accepted before root_issuer_registered for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if e.RootIssuerKeyID != p.RootIssuer.KeyID || e.RootIssuerPublicKeyFingerprint != p.RootIssuer.PublicKeyFingerprint {
			return nil, fmt.Errorf("%w: event %d manifest root issuer mismatch for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		prevDigest, err := VerifyManifestAcceptedEvent(e, *p.RootIssuer)
		if err != nil {
			return nil, fmt.Errorf("%w: event %d manifest signature invalid: %v", ErrMalformedDurableEvent, index, err)
		}
		if e.ManifestVersion != p.ManifestVersion+1 {
			return nil, fmt.Errorf("%w: event %d manifest version %d does not extend current %d for pool %q", ErrMalformedDurableEvent, index, e.ManifestVersion, p.ManifestVersion, e.PoolID)
		}
		wantPrev := strings.Repeat("0", 64)
		if p.ManifestVersion != 0 {
			wantPrev = p.ManifestCoreDigest
		}
		if prevDigest != wantPrev {
			return nil, fmt.Errorf("%w: event %d manifest prev hash %q does not match current digest %q for pool %q", ErrMalformedDurableEvent, index, prevDigest, wantPrev, e.PoolID)
		}
		p.ManifestVersion = e.ManifestVersion
		p.ManifestCoreDigest = e.ManifestCoreDigest
	case EventLifecycleChanged:
		if e.Lifecycle == LifecycleActive && p.ManifestVersion == 0 {
			return nil, fmt.Errorf("%w: event %d active lifecycle before manifest_accepted for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if !validLifecycleTransition(p.Lifecycle, e.Lifecycle) {
			return nil, fmt.Errorf("%w: event %d invalid lifecycle transition %s -> %s for pool %q", ErrMalformedDurableEvent, index, p.Lifecycle, e.Lifecycle, e.PoolID)
		}
		p.Lifecycle = e.Lifecycle
		p.LifecycleReason = e.Reason
	case EventMemberAdmitted:
		if !p.Revoked[e.ProviderID] {
			p.Members[e.ProviderID] = true
		}
	case EventMemberRevoked:
		delete(p.Members, e.ProviderID)
		p.Revoked[e.ProviderID] = true
	case EventBuyerAuthorized:
		p.BuyerAccounts[e.BuyerAccountID] = true
	case EventBuyerAuthorizationRm:
		delete(p.BuyerAccounts, e.BuyerAccountID)
	case EventMinBinaryVersionSet:
		if e.MinBinaryVersion == "" && p.MinBinaryVersion != "" {
			return nil, fmt.Errorf("%w: event %d clears min binary version for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if p.MinBinaryVersion != "" && e.MinBinaryVersion != "" {
			cmp, ok := versionfloor.Compare(e.MinBinaryVersion, p.MinBinaryVersion)
			if !ok || cmp < 0 {
				return nil, fmt.Errorf("%w: event %d lowers min binary version from %q to %q for pool %q", ErrMalformedDurableEvent, index, p.MinBinaryVersion, e.MinBinaryVersion, e.PoolID)
			}
		}
		p.MinBinaryVersion = e.MinBinaryVersion
	default:
		return nil, fmt.Errorf("trustpool: unknown event type %q", e.EventType)
	}
	return p, nil
}

func (s *ReconstructedState) rootFingerprintOwner(fingerprint string) (string, bool) {
	for poolID, p := range s.Pools {
		if p.RootIssuer != nil && p.RootIssuer.PublicKeyFingerprint == fingerprint {
			return poolID, true
		}
	}
	return "", false
}

func (s *ReconstructedState) applyCreatorRouteGates() {
	if s == nil || s.CreatorApprovals == nil {
		return
	}
	for _, p := range s.Pools {
		p.CreatorGateReason = ""
		approval, ok := s.CreatorApprovals[p.CreatorAccountID]
		if !ok {
			p.CreatorGateReason = "creator_approval_missing"
			p.RouteableGeneration = p.Generation + 1
			continue
		}
		p.RouteableGeneration = p.Generation + approval.ApprovalRevision
		version := ""
		environment := ""
		if p.RootIssuer != nil {
			version = p.RootIssuer.CurrentApprovalVersion
			environment = p.RootIssuer.LaunchEnvironment
		}
		if version == "" {
			version = approval.CurrentApprovalVersion
		}
		if environment == "" {
			environment = approval.AllowedLaunchEnvironment
		}
		if !approval.ValidFor(p.ApprovalRecordID, version, environment, s.RouteGateCheckedAt) {
			p.CreatorGateReason = approval.InvalidReason(p.ApprovalRecordID, version, environment, s.RouteGateCheckedAt)
			continue
		}
		p.CreatorGateExpiresAtUTC = approval.CreatorAgreementGraceEndsAtUTC
	}
}

func (s *ReconstructedState) validateMutationCreatorGate(e DurableEvent, now time.Time) error {
	if s == nil || s.CreatorApprovals == nil {
		return nil
	}
	creatorID := e.CreatorAccountID
	approvalID := e.ApprovalRecordID
	version := e.CurrentApprovalVersion
	environment := e.LaunchEnvironment
	if e.EventType != EventPoolCreated && e.EventType != EventRootIssuerRegistered {
		p := s.Pools[e.PoolID]
		if p == nil {
			return ErrMalformedDurableEvent
		}
		creatorID = p.CreatorAccountID
		approvalID = p.ApprovalRecordID
		if p.RootIssuer != nil {
			version = p.RootIssuer.CurrentApprovalVersion
			environment = p.RootIssuer.LaunchEnvironment
		}
	}
	if creatorID == "" || approvalID == "" {
		return ErrCreatorApprovalGate
	}
	approval, ok := s.CreatorApprovals[creatorID]
	if !ok {
		return ErrCreatorApprovalGate
	}
	if version == "" {
		version = approval.CurrentApprovalVersion
	}
	if environment == "" {
		environment = approval.AllowedLaunchEnvironment
	}
	if mutationRequiresEnabledCreator(e) && !approval.ValidFor(approvalID, version, environment, now) {
		return ErrCreatorApprovalGate
	}
	return nil
}

func mutationRequiresEnabledCreator(e DurableEvent) bool {
	switch e.EventType {
	case EventPoolCreated, EventRootIssuerRegistered, EventManifestAccepted, EventMemberAdmitted, EventBuyerAuthorized:
		return true
	case EventLifecycleChanged:
		return e.Lifecycle == LifecycleActive
	case EventMinBinaryVersionSet:
		return true
	default:
		return false
	}
}

func (s *ReconstructedState) RouteableSnapshots() []RouteableSnapshot {
	if s == nil {
		return nil
	}
	ids := make([]string, 0, len(s.Pools))
	for id := range s.Pools {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]RouteableSnapshot, 0, len(ids))
	for _, id := range ids {
		p := s.Pools[id]
		routeable := p.Lifecycle == LifecycleActive && p.CreatorGateReason == ""
		members := make([]string, 0, len(p.Members))
		if routeable {
			for id := range p.Members {
				if !p.Revoked[id] {
					members = append(members, id)
				}
			}
		}
		revoked := make([]string, 0, len(p.Revoked))
		for id := range p.Revoked {
			revoked = append(revoked, id)
		}
		buyers := make([]string, 0, len(p.BuyerAccounts))
		for id := range p.BuyerAccounts {
			buyers = append(buyers, id)
		}
		sort.Strings(members)
		sort.Strings(revoked)
		sort.Strings(buyers)
		out = append(out, RouteableSnapshot{
			PoolID:            p.PoolID,
			Members:           members,
			Revoked:           revoked,
			BuyerAccounts:     buyers,
			MinBinaryVersion:  p.MinBinaryVersion,
			Routeable:         routeable,
			Generation:        p.EffectiveGeneration(),
			RouteableUntilUTC: p.CreatorGateExpiresAtUTC,
		})
	}
	return out
}

func (p *ReconstructedPoolState) EffectiveGeneration() uint64 {
	if p == nil {
		return 0
	}
	if p.RouteableGeneration != 0 {
		return p.RouteableGeneration
	}
	return p.Generation
}

func (s *ReconstructedState) BuildRegistry() (*Registry, error) {
	r := NewRegistry()
	if err := r.LoadRouteableSnapshotsAtRevision(s.Revision, s.RouteableSnapshots()); err != nil {
		return nil, err
	}
	return r, nil
}

func (s *ReconstructedState) ensurePool(poolID string) *ReconstructedPoolState {
	p := s.Pools[poolID]
	if p != nil {
		return p
	}
	p = &ReconstructedPoolState{
		PoolID:        poolID,
		Lifecycle:     LifecycleCreated,
		Members:       make(map[string]bool),
		Revoked:       make(map[string]bool),
		BuyerAccounts: make(map[string]bool),
	}
	s.Pools[poolID] = p
	return p
}

func validateEvent(e DurableEvent) error {
	if e.OperationID == "" {
		return fmt.Errorf("operation_id is required")
	}
	if e.TimestampUTC.IsZero() {
		return fmt.Errorf("timestamp_utc is required")
	}
	if e.PoolID == "" {
		return fmt.Errorf("pool_id is required")
	}
	switch e.EventType {
	case EventPoolCreated:
		if e.CreatorAccountID == "" || e.ApprovalRecordID == "" {
			return fmt.Errorf("pool_created requires creator_account_id and approval_record_id")
		}
	case EventRootIssuerRegistered:
		if e.CreatorAccountID == "" || e.ApprovalRecordID == "" || e.CurrentApprovalVersion == "" {
			return fmt.Errorf("root_issuer_registered requires creator_account_id, approval_record_id, and current_approval_version")
		}
		if e.RootIssuerKeyID == "" || e.RootIssuerPublicKeyDER == "" || e.RootIssuerPublicKeyFingerprint == "" ||
			e.RootSignatureAlgorithm == "" || e.RootRegistrationSignature == "" {
			return fmt.Errorf("root_issuer_registered requires root issuer key fields and proof")
		}
		if e.ManifestAuthorityRootKeyID == "" || e.ManifestAuthorityRootPublicKey == "" {
			return fmt.Errorf("root_issuer_registered requires delegated manifest authority root")
		}
		if e.StructuredKeyCustodyDisclosureHash == "" || e.GenesisNonceDigest == "" ||
			e.IntendedPoolDisplayNameHash == "" || e.LaunchEnvironment == "" {
			return fmt.Errorf("root_issuer_registered requires custody, genesis, display, and launch environment bindings")
		}
		if e.RootRegistrationNonce == "" || e.RootRegistrationNonceExpiry == "" ||
			e.RootRegistrationPurpose == "" || e.RootRegistrationEnvironment == "" {
			return fmt.Errorf("root_issuer_registered requires nonce commitment fields")
		}
	case EventManifestAccepted:
		if e.ManifestVersion == 0 || e.ManifestCoreDigest == "" || e.ManifestSignature == "" || e.ManifestSnapshot == "" {
			return fmt.Errorf("manifest_accepted requires manifest_version, manifest_core_digest, manifest_snapshot, and manifest_signature")
		}
		if e.RootIssuerKeyID == "" || e.RootIssuerPublicKeyFingerprint == "" {
			return fmt.Errorf("manifest_accepted requires root issuer binding")
		}
	case EventLifecycleChanged:
		if !validLifecycle(e.Lifecycle) {
			return fmt.Errorf("invalid lifecycle %q", e.Lifecycle)
		}
	case EventMemberAdmitted, EventMemberRevoked:
		if e.ProviderID == "" {
			return fmt.Errorf("%s requires provider_id", e.EventType)
		}
	case EventBuyerAuthorized, EventBuyerAuthorizationRm:
		if e.BuyerAccountID == "" {
			return fmt.Errorf("%s requires buyer_account_id", e.EventType)
		}
	case EventMinBinaryVersionSet:
		if e.MinBinaryVersion != "" && !versionfloor.Valid(e.MinBinaryVersion) {
			return fmt.Errorf("invalid min_binary_version %q", e.MinBinaryVersion)
		}
	default:
		return fmt.Errorf("unknown event type %q", e.EventType)
	}
	return nil
}

func validLifecycle(v string) bool {
	switch v {
	case LifecycleCreated, LifecycleActive, LifecyclePaused, LifecycleDraining, LifecycleRetired:
		return true
	default:
		return false
	}
}

func validLifecycleTransition(from, to string) bool {
	switch from {
	case LifecycleCreated:
		return to == LifecycleActive || to == LifecycleRetired
	case LifecycleActive:
		return to == LifecyclePaused || to == LifecycleDraining || to == LifecycleRetired
	case LifecyclePaused:
		return to == LifecycleDraining || to == LifecycleRetired
	case LifecycleDraining:
		return to == LifecycleRetired
	case LifecycleRetired:
		return false
	default:
		return false
	}
}

func nullString(v string) sql.NullString {
	if v == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: v, Valid: true}
}

func normalizeCreatorApproval(a CreatorApproval) CreatorApproval {
	a.CreatorAccountID = strings.TrimSpace(a.CreatorAccountID)
	a.ApprovalRecordID = strings.TrimSpace(a.ApprovalRecordID)
	a.CurrentApprovalVersion = strings.TrimSpace(a.CurrentApprovalVersion)
	a.PublicDisplayName = strings.TrimSpace(a.PublicDisplayName)
	a.LegalSupportContact = strings.TrimSpace(a.LegalSupportContact)
	a.BillingContact = strings.TrimSpace(a.BillingContact)
	a.EmergencyNotificationEndpoint = strings.TrimSpace(a.EmergencyNotificationEndpoint)
	a.AcknowledgedMaxResponseTime = strings.TrimSpace(a.AcknowledgedMaxResponseTime)
	a.AllowedProductCategory = strings.TrimSpace(a.AllowedProductCategory)
	a.DataRetentionCategory = strings.TrimSpace(a.DataRetentionCategory)
	a.SupportOwner = strings.TrimSpace(a.SupportOwner)
	a.AllowedLaunchEnvironment = strings.TrimSpace(a.AllowedLaunchEnvironment)
	a.CreatorAgreementID = strings.TrimSpace(a.CreatorAgreementID)
	a.CreatorAgreementVersion = strings.TrimSpace(a.CreatorAgreementVersion)
	a.PricingScheduleID = strings.TrimSpace(a.PricingScheduleID)
	a.PricingScheduleVersion = strings.TrimSpace(a.PricingScheduleVersion)
	a.ProhibitedClaimAcknowledgmentHash = strings.TrimSpace(a.ProhibitedClaimAcknowledgmentHash)
	a.BuyerDisclosureCommitmentHash = strings.TrimSpace(a.BuyerDisclosureCommitmentHash)
	a.ApprovalCriteriaHash = strings.TrimSpace(a.ApprovalCriteriaHash)
	a.ApprovedBy = strings.TrimSpace(a.ApprovedBy)
	a.Status = strings.TrimSpace(a.Status)
	a.SuspensionReason = strings.TrimSpace(a.SuspensionReason)
	if a.Status == "" {
		a.Status = CreatorStatusEnabled
	}
	a.CreatorAgreementExpiresAtUTC = a.CreatorAgreementExpiresAtUTC.UTC()
	a.CreatorAgreementGraceEndsAtUTC = a.CreatorAgreementGraceEndsAtUTC.UTC()
	a.ApprovedAtUTC = a.ApprovedAtUTC.UTC()
	a.UpdatedAtUTC = a.UpdatedAtUTC.UTC()
	return a
}

func validateCreatorApproval(a CreatorApproval) error {
	if a.CreatorAccountID == "" || a.ApprovalRecordID == "" || a.CurrentApprovalVersion == "" ||
		a.PublicDisplayName == "" || a.LegalSupportContact == "" || a.BillingContact == "" ||
		a.EmergencyNotificationEndpoint == "" || a.AcknowledgedMaxResponseTime == "" ||
		a.AllowedProductCategory == "" || a.DataRetentionCategory == "" || a.SupportOwner == "" ||
		a.AllowedLaunchEnvironment == "" || a.CreatorAgreementID == "" || a.CreatorAgreementVersion == "" ||
		a.PricingScheduleID == "" || a.PricingScheduleVersion == "" ||
		a.ProhibitedClaimAcknowledgmentHash == "" || a.BuyerDisclosureCommitmentHash == "" ||
		a.ApprovalCriteriaHash == "" || a.ApprovedBy == "" ||
		a.CreatorAgreementExpiresAtUTC.IsZero() || a.CreatorAgreementGraceEndsAtUTC.IsZero() || a.ApprovedAtUTC.IsZero() {
		return ErrCreatorApprovalGate
	}
	if a.CreatorAgreementGraceEndsAtUTC.Before(a.CreatorAgreementExpiresAtUTC) {
		return ErrCreatorApprovalGate
	}
	if !validSHA256Hex(a.ProhibitedClaimAcknowledgmentHash) ||
		!validSHA256Hex(a.BuyerDisclosureCommitmentHash) ||
		!validSHA256Hex(a.ApprovalCriteriaHash) {
		return ErrCreatorApprovalGate
	}
	switch a.Status {
	case CreatorStatusEnabled:
		return nil
	case CreatorStatusSuspended:
		if a.SuspensionReason == "" {
			return ErrCreatorApprovalGate
		}
		return nil
	default:
		return ErrCreatorApprovalGate
	}
}

func sameCreatorApprovalExceptRevision(a, b CreatorApproval) bool {
	a = normalizeCreatorApproval(a)
	b = normalizeCreatorApproval(b)
	a.ApprovalRevision = 0
	b.ApprovalRevision = 0
	a.UpdatedAtUTC = time.Time{}
	b.UpdatedAtUTC = time.Time{}
	return a == b
}

func validSHA256Hex(v string) bool {
	if len(v) != 64 {
		return false
	}
	for _, c := range v {
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return false
	}
	return true
}

func (a CreatorApproval) ValidFor(approvalRecordID, currentApprovalVersion, launchEnvironment string, now time.Time) bool {
	return a.InvalidReason(approvalRecordID, currentApprovalVersion, launchEnvironment, now) == ""
}

func (a CreatorApproval) InvalidReason(approvalRecordID, currentApprovalVersion, launchEnvironment string, now time.Time) string {
	approvalRecordID = strings.TrimSpace(approvalRecordID)
	currentApprovalVersion = strings.TrimSpace(currentApprovalVersion)
	launchEnvironment = strings.TrimSpace(launchEnvironment)
	now = now.UTC()
	switch {
	case a.CreatorAccountID == "":
		return "creator_approval_missing"
	case a.Status != CreatorStatusEnabled:
		return "creator_suspended"
	case approvalRecordID == "" || approvalRecordID != a.ApprovalRecordID:
		return "approval_record_mismatch"
	case currentApprovalVersion == "" || currentApprovalVersion != a.CurrentApprovalVersion:
		return "approval_version_mismatch"
	case launchEnvironment == "" || launchEnvironment != a.AllowedLaunchEnvironment:
		return "launch_environment_mismatch"
	case a.CreatorAgreementGraceEndsAtUTC.IsZero() || !now.Before(a.CreatorAgreementGraceEndsAtUTC):
		return "creator_agreement_expired"
	default:
		return ""
	}
}
