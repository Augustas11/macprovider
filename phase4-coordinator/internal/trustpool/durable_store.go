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
	"unicode/utf8"

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

	promotionLaunchEnvironmentCandidate = "candidate"
)

var (
	ErrStoreClosed                 = errors.New("trustpool: store is closed")
	ErrConflictingOperationID      = errors.New("trustpool: conflicting operation id")
	ErrMalformedDurableEvent       = errors.New("trustpool: malformed durable event history")
	ErrActivationRequiresPromotion = errors.New("trustpool: active lifecycle requires promotion gate")
	ErrPromotionPreconditionFailed = errors.New("trustpool: promotion precondition failed")
	ErrRootRegistrationNonce       = errors.New("trustpool: invalid root registration nonce")
	ErrCreatorApprovalGate         = errors.New("trustpool: creator approval gate failed")
	ErrPublicAnnouncementGate      = errors.New("trustpool: public announcement gate failed")
	ErrProhibitedPromiseClaim      = errors.New("trustpool: prohibited promise claim")
	ErrSignedControlProofPath      = errors.New("trustpool: signed control proof requires signed lifecycle path")
)

type PromotionPreconditionError struct {
	Reason string
}

func (e PromotionPreconditionError) Error() string {
	if e.Reason == "" {
		return ErrPromotionPreconditionFailed.Error()
	}
	return ErrPromotionPreconditionFailed.Error() + ": " + e.Reason
}

func (e PromotionPreconditionError) Is(target error) bool {
	return target == ErrPromotionPreconditionFailed
}

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
	SignedControl      string    `json:"signed_control,omitempty"`
	ControlSignatures  string    `json:"control_signatures,omitempty"`

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

type PublicAnnouncementApproval struct {
	OperationID                string    `json:"operation_id"`
	PoolID                     string    `json:"pool_id"`
	ManifestCoreDigest         string    `json:"manifest_core_digest"`
	ReviewedDistributionDigest string    `json:"reviewed_distribution_artifact_digest"`
	CreatorAccountID           string    `json:"creator_account_id"`
	CreatorApprovalRecordID    string    `json:"creator_approval_record_id"`
	CreatorApprovalVersion     string    `json:"creator_approval_version"`
	CreatorApprovalRevision    uint64    `json:"creator_approval_revision"`
	ApprovalRecordID           string    `json:"approval_record_id"`
	ApprovedBy                 string    `json:"approved_by"`
	ApprovedAtUTC              time.Time `json:"approved_at_utc"`
	PublicAnnouncementRevision uint64    `json:"public_announcement_revision"`
	UpdatedAtUTC               time.Time `json:"updated_at_utc"`
}

type ReviewedDistributionArtifact struct {
	OperationID                string    `json:"operation_id"`
	PoolID                     string    `json:"pool_id"`
	ManifestCoreDigest         string    `json:"manifest_core_digest"`
	ReviewedDistributionDigest string    `json:"reviewed_distribution_artifact_digest"`
	ArtifactURI                string    `json:"artifact_uri"`
	ClaimControlDigest         string    `json:"claim_control_artifact_digest"`
	ReviewedBy                 string    `json:"reviewed_by"`
	ReviewedAtUTC              time.Time `json:"reviewed_at_utc"`
	ReviewRevision             uint64    `json:"review_revision"`
	UpdatedAtUTC               time.Time `json:"updated_at_utc"`
}

type ManifestAcceptanceProjection struct {
	PoolID                 string
	ManifestVersion        uint64
	OperationID            string
	AcceptedAtUTC          time.Time
	ManifestCoreDigest     string
	RootIssuerKeyID        string
	RootIssuerPublicKeyFP  string
	ManifestSignature      string
	ManifestSnapshotSHA256 string
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
	    operation_id TEXT,
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
	CREATE TABLE IF NOT EXISTS trustpool_public_announcements (
	    pool_id TEXT PRIMARY KEY,
	    operation_id TEXT NOT NULL,
	    manifest_core_digest TEXT NOT NULL,
	    reviewed_distribution_artifact_digest TEXT NOT NULL,
	    creator_account_id TEXT NOT NULL,
	    creator_approval_record_id TEXT NOT NULL,
	    creator_approval_version TEXT NOT NULL,
	    creator_approval_revision INTEGER NOT NULL DEFAULT 0,
	    approval_record_id TEXT NOT NULL,
	    approved_by TEXT NOT NULL,
	    approved_at_utc TEXT NOT NULL,
	    public_announcement_revision INTEGER NOT NULL DEFAULT 0,
	    updated_at_utc TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS trustpool_public_announcement_history (
	    id INTEGER PRIMARY KEY AUTOINCREMENT,
	    operation_id TEXT NOT NULL UNIQUE,
	    pool_id TEXT NOT NULL,
	    manifest_core_digest TEXT NOT NULL,
	    reviewed_distribution_artifact_digest TEXT NOT NULL,
	    creator_account_id TEXT NOT NULL,
	    creator_approval_record_id TEXT NOT NULL,
	    creator_approval_version TEXT NOT NULL,
	    creator_approval_revision INTEGER NOT NULL DEFAULT 0,
	    approval_record_id TEXT NOT NULL,
	    approved_by TEXT NOT NULL,
	    approved_at_utc TEXT NOT NULL,
	    public_announcement_revision INTEGER NOT NULL DEFAULT 0,
	    updated_at_utc TEXT NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_trustpool_public_announcement_history_pool ON trustpool_public_announcement_history(pool_id, id);
	CREATE INDEX IF NOT EXISTS idx_trustpool_public_announcements_digest ON trustpool_public_announcements(manifest_core_digest, updated_at_utc);
	CREATE TABLE IF NOT EXISTS trustpool_reviewed_distribution_artifacts (
	    pool_id TEXT PRIMARY KEY,
	    operation_id TEXT NOT NULL,
	    manifest_core_digest TEXT NOT NULL,
	    reviewed_distribution_artifact_digest TEXT NOT NULL,
	    artifact_uri TEXT NOT NULL,
	    claim_control_artifact_digest TEXT NOT NULL,
	    reviewed_by TEXT NOT NULL,
	    reviewed_at_utc TEXT NOT NULL,
	    review_revision INTEGER NOT NULL DEFAULT 0,
	    updated_at_utc TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS trustpool_reviewed_distribution_artifact_history (
	    id INTEGER PRIMARY KEY AUTOINCREMENT,
	    operation_id TEXT NOT NULL UNIQUE,
	    pool_id TEXT NOT NULL,
	    manifest_core_digest TEXT NOT NULL,
	    reviewed_distribution_artifact_digest TEXT NOT NULL,
	    artifact_uri TEXT NOT NULL,
	    claim_control_artifact_digest TEXT NOT NULL,
	    reviewed_by TEXT NOT NULL,
	    reviewed_at_utc TEXT NOT NULL,
	    review_revision INTEGER NOT NULL DEFAULT 0,
	    updated_at_utc TEXT NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_trustpool_reviewed_distribution_history_pool ON trustpool_reviewed_distribution_artifact_history(pool_id, id);
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
	if err := s.ensureColumn(ctx, "trustpool_root_registration_nonces", "operation_id", "TEXT"); err != nil {
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
	if _, err := s.db.ExecContext(ctx, `CREATE INDEX IF NOT EXISTS idx_trustpool_events_root_fingerprint ON trustpool_events(root_issuer_public_key_fingerprint, id)`); err != nil {
		return err
	}
	for _, c := range []struct {
		name string
		decl string
	}{
		{name: "operation_id", decl: "TEXT NOT NULL DEFAULT ''"},
		{name: "reviewed_distribution_artifact_digest", decl: "TEXT NOT NULL DEFAULT ''"},
		{name: "creator_account_id", decl: "TEXT NOT NULL DEFAULT ''"},
		{name: "creator_approval_record_id", decl: "TEXT NOT NULL DEFAULT ''"},
		{name: "creator_approval_version", decl: "TEXT NOT NULL DEFAULT ''"},
		{name: "creator_approval_revision", decl: "INTEGER NOT NULL DEFAULT 0"},
	} {
		if err := s.ensureColumn(ctx, "trustpool_public_announcements", c.name, c.decl); err != nil {
			return err
		}
	}
	if _, err := s.db.ExecContext(ctx, `CREATE UNIQUE INDEX IF NOT EXISTS idx_trustpool_public_announcement_history_operation ON trustpool_public_announcement_history(operation_id)`); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, `CREATE UNIQUE INDEX IF NOT EXISTS idx_trustpool_reviewed_distribution_history_operation ON trustpool_reviewed_distribution_artifact_history(operation_id)`); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, `CREATE UNIQUE INDEX IF NOT EXISTS idx_trustpool_root_registration_nonces_operation ON trustpool_root_registration_nonces(operation_id) WHERE operation_id IS NOT NULL`); err != nil {
		return err
	}
	return s.migrateManifestAcceptanceTables(ctx)
}

func (s *Store) migrateManifestAcceptanceTables(ctx context.Context) error {
	return sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS trustpool_manifest_acceptances (
    pool_id TEXT NOT NULL,
    manifest_version INTEGER NOT NULL,
    operation_id TEXT NOT NULL UNIQUE,
    accepted_at_utc TEXT NOT NULL,
    manifest_core_digest TEXT NOT NULL,
    root_issuer_key_id TEXT NOT NULL,
    root_issuer_public_key_fingerprint TEXT NOT NULL,
    manifest_signature TEXT NOT NULL,
    manifest_snapshot_sha256 TEXT NOT NULL,
    PRIMARY KEY(pool_id, manifest_version)
);
CREATE TABLE IF NOT EXISTS trustpool_manifest_acceptance_high_water (
    pool_id TEXT PRIMARY KEY,
    manifest_version INTEGER NOT NULL,
    operation_id TEXT NOT NULL UNIQUE,
    accepted_at_utc TEXT NOT NULL,
    manifest_core_digest TEXT NOT NULL,
    root_issuer_key_id TEXT NOT NULL,
    root_issuer_public_key_fingerprint TEXT NOT NULL,
    manifest_signature TEXT NOT NULL,
    manifest_snapshot_sha256 TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS trustpool_manifest_acceptance_migration (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    completed_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trustpool_manifest_acceptances_operation ON trustpool_manifest_acceptances(operation_id);
`); err != nil {
			return err
		}
		events, err := eventsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		var completedAt string
		err = conn.QueryRowContext(ctx, `SELECT completed_at_utc FROM trustpool_manifest_acceptance_migration WHERE id = 1`).Scan(&completedAt)
		switch {
		case err == nil:
			if _, err := time.Parse(time.RFC3339Nano, completedAt); err != nil {
				return fmt.Errorf("%w: manifest acceptance migration completed_at_utc: %v", ErrMalformedDurableEvent, err)
			}
		case errors.Is(err, sql.ErrNoRows):
			for _, e := range events {
				if e.EventType != EventManifestAccepted {
					continue
				}
				if err := insertManifestAcceptanceProjection(ctx, conn, e); err != nil {
					return err
				}
			}
			if err := verifyManifestAcceptanceState(ctx, conn, events); err != nil {
				return err
			}
			_, err = conn.ExecContext(ctx, `INSERT INTO trustpool_manifest_acceptance_migration (id, completed_at_utc) VALUES (1, ?)`, time.Now().UTC().Format(time.RFC3339Nano))
			return err
		default:
			return err
		}
		return verifyManifestAcceptanceState(ctx, conn, events)
	})
}

type RootRegistrationNonceIssue struct {
	OperationID            string    `json:"operation_id"`
	CreatorAccountID       string    `json:"creator_account_id"`
	ApprovalRecordID       string    `json:"approval_record_id"`
	CurrentApprovalVersion string    `json:"current_approval_version"`
	LaunchEnvironment      string    `json:"launch_environment"`
	Purpose                string    `json:"purpose,omitempty"`
	ExpiresAtUTC           time.Time `json:"expires_at_utc"`
}

type RootRegistrationNonceRecord struct {
	Nonce                  string    `json:"nonce"`
	OperationID            string    `json:"operation_id"`
	CreatorAccountID       string    `json:"creator_account_id"`
	ApprovalRecordID       string    `json:"approval_record_id"`
	CurrentApprovalVersion string    `json:"current_approval_version"`
	LaunchEnvironment      string    `json:"launch_environment"`
	Purpose                string    `json:"purpose"`
	ExpiresAtUTC           time.Time `json:"expires_at_utc"`
	IssuedAtUTC            time.Time `json:"issued_at_utc"`
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
		if err := verifyManifestAcceptanceStateFromQueryer(ctx, conn); err != nil {
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

func verifyManifestAcceptanceStateFromQueryer(ctx context.Context, q eventQueryer) error {
	events, err := eventsFromQueryer(ctx, q)
	if err != nil {
		return err
	}
	return verifyManifestAcceptanceState(ctx, q, events)
}

func (s *Store) UpsertReviewedDistributionArtifact(ctx context.Context, artifact ReviewedDistributionArtifact) (ReviewedDistributionArtifact, error) {
	if s == nil || s.db == nil {
		return ReviewedDistributionArtifact{}, ErrStoreClosed
	}
	artifact = normalizeReviewedDistributionArtifact(artifact)
	if err := validateReviewedDistributionArtifact(artifact); err != nil {
		return ReviewedDistributionArtifact{}, err
	}
	now := time.Now().UTC()
	artifact.UpdatedAtUTC = now
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		events, err := eventsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if err := verifyManifestAcceptanceState(ctx, conn, events); err != nil {
			return err
		}
		if existing, ok, err := reviewedDistributionArtifactByOperationID(ctx, conn, artifact.OperationID); err != nil {
			return err
		} else if ok {
			if reviewedDistributionArtifactMatchesOperation(existing, artifact) {
				artifact = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		if used, err := operationIDExists(ctx, conn, artifact.OperationID); err != nil {
			return err
		} else if used {
			return ErrConflictingOperationID
		}
		creatorApprovals, err := creatorApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		state, err := reconstructEventsWithApprovals(events, creatorApprovals, now)
		if err != nil {
			return err
		}
		p := state.Pools[artifact.PoolID]
		if p == nil || p.ManifestCoreDigest == "" || p.ManifestCoreDigest != artifact.ManifestCoreDigest {
			return ErrPublicAnnouncementGate
		}
		if _, ok := currentPublicAnnouncementBinding(state, p); !ok {
			return ErrPublicAnnouncementGate
		}
		current, err := reviewedDistributionArtifactsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if existing, ok := current[artifact.PoolID]; ok && sameReviewedDistributionArtifactExceptRevision(existing, artifact) {
			if existing.OperationID == artifact.OperationID {
				artifact = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		artifact.ReviewRevision = current[artifact.PoolID].ReviewRevision + 1
		if _, err := conn.ExecContext(ctx, `
	INSERT INTO trustpool_reviewed_distribution_artifact_history (
	    operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	    artifact_uri, claim_control_artifact_digest, reviewed_by, reviewed_at_utc,
	    review_revision, updated_at_utc
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			artifact.OperationID,
			artifact.PoolID,
			artifact.ManifestCoreDigest,
			artifact.ReviewedDistributionDigest,
			artifact.ArtifactURI,
			artifact.ClaimControlDigest,
			artifact.ReviewedBy,
			artifact.ReviewedAtUTC.Format(time.RFC3339Nano),
			artifact.ReviewRevision,
			artifact.UpdatedAtUTC.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
	INSERT INTO trustpool_reviewed_distribution_artifacts (
	    pool_id, operation_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	    artifact_uri, claim_control_artifact_digest, reviewed_by, reviewed_at_utc,
	    review_revision, updated_at_utc
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(pool_id) DO UPDATE SET
	    operation_id = excluded.operation_id,
	    manifest_core_digest = excluded.manifest_core_digest,
	    reviewed_distribution_artifact_digest = excluded.reviewed_distribution_artifact_digest,
	    artifact_uri = excluded.artifact_uri,
	    claim_control_artifact_digest = excluded.claim_control_artifact_digest,
	    reviewed_by = excluded.reviewed_by,
	    reviewed_at_utc = excluded.reviewed_at_utc,
	    review_revision = excluded.review_revision,
	    updated_at_utc = excluded.updated_at_utc`,
			artifact.PoolID,
			artifact.OperationID,
			artifact.ManifestCoreDigest,
			artifact.ReviewedDistributionDigest,
			artifact.ArtifactURI,
			artifact.ClaimControlDigest,
			artifact.ReviewedBy,
			artifact.ReviewedAtUTC.Format(time.RFC3339Nano),
			artifact.ReviewRevision,
			artifact.UpdatedAtUTC.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return ReviewedDistributionArtifact{}, err
	}
	return artifact, nil
}

func (s *Store) ReviewedDistributionArtifact(ctx context.Context, poolID string) (ReviewedDistributionArtifact, bool, error) {
	if s == nil || s.db == nil {
		return ReviewedDistributionArtifact{}, false, ErrStoreClosed
	}
	return reviewedDistributionArtifactFromQueryer(ctx, s.db, strings.TrimSpace(poolID))
}

func (s *Store) ReviewedDistributionArtifactHistory(ctx context.Context, poolID string) ([]ReviewedDistributionArtifact, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	return reviewedDistributionArtifactHistoryFromQueryer(ctx, s.db, strings.TrimSpace(poolID))
}

func (s *Store) reviewedDistributionArtifacts(ctx context.Context) (map[string]ReviewedDistributionArtifact, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	return reviewedDistributionArtifactsFromQueryer(ctx, s.db)
}

func (s *Store) UpsertPublicAnnouncementApproval(ctx context.Context, approval PublicAnnouncementApproval) (PublicAnnouncementApproval, error) {
	if s == nil || s.db == nil {
		return PublicAnnouncementApproval{}, ErrStoreClosed
	}
	approval = normalizePublicAnnouncementApproval(approval)
	if err := validatePublicAnnouncementApproval(approval); err != nil {
		return PublicAnnouncementApproval{}, err
	}
	now := time.Now().UTC()
	approval.UpdatedAtUTC = now
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		events, err := eventsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if err := verifyManifestAcceptanceState(ctx, conn, events); err != nil {
			return err
		}
		if existing, ok, err := publicAnnouncementApprovalByOperationID(ctx, conn, approval.OperationID); err != nil {
			return err
		} else if ok {
			if publicAnnouncementApprovalMatchesOperation(existing, approval) {
				approval = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		if used, err := operationIDExists(ctx, conn, approval.OperationID); err != nil {
			return err
		} else if used {
			return ErrConflictingOperationID
		}
		creatorApprovals, err := creatorApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		state, err := reconstructEventsWithApprovals(events, creatorApprovals, now)
		if err != nil {
			return err
		}
		p := state.Pools[approval.PoolID]
		if p == nil || p.ManifestCoreDigest == "" || p.ManifestCoreDigest != approval.ManifestCoreDigest {
			return ErrPublicAnnouncementGate
		}
		artifact, ok, err := reviewedDistributionArtifactFromQueryer(ctx, conn, approval.PoolID)
		if err != nil {
			return err
		}
		if !ok || artifact.ManifestCoreDigest != approval.ManifestCoreDigest || artifact.ReviewedDistributionDigest != approval.ReviewedDistributionDigest {
			return ErrPublicAnnouncementGate
		}
		binding, ok := currentPublicAnnouncementBinding(state, p)
		if !ok {
			return ErrPublicAnnouncementGate
		}
		if !publicAnnouncementLaunchAllowed(p) {
			return ErrPublicAnnouncementGate
		}
		approval.CreatorAccountID = binding.CreatorAccountID
		approval.CreatorApprovalRecordID = binding.CreatorApprovalRecordID
		approval.CreatorApprovalVersion = binding.CreatorApprovalVersion
		approval.CreatorApprovalRevision = binding.CreatorApprovalRevision
		if err := validateStoredPublicAnnouncementApproval(approval); err != nil {
			return err
		}
		currentApprovals, err := publicAnnouncementApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if current, ok := currentApprovals[approval.PoolID]; ok && samePublicAnnouncementApprovalExceptRevision(current, approval) {
			approval = current
			return nil
		}
		approval.PublicAnnouncementRevision = currentApprovals[approval.PoolID].PublicAnnouncementRevision + 1
		if _, err := conn.ExecContext(ctx, `
	INSERT INTO trustpool_public_announcement_history (
	    operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	    creator_account_id, creator_approval_record_id, creator_approval_version,
	    creator_approval_revision, approval_record_id, approved_by, approved_at_utc,
	    public_announcement_revision, updated_at_utc
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			approval.OperationID,
			approval.PoolID,
			approval.ManifestCoreDigest,
			approval.ReviewedDistributionDigest,
			approval.CreatorAccountID,
			approval.CreatorApprovalRecordID,
			approval.CreatorApprovalVersion,
			approval.CreatorApprovalRevision,
			approval.ApprovalRecordID,
			approval.ApprovedBy,
			approval.ApprovedAtUTC.Format(time.RFC3339Nano),
			approval.PublicAnnouncementRevision,
			approval.UpdatedAtUTC.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, `
	INSERT INTO trustpool_public_announcements (
	    pool_id, operation_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	    creator_account_id, creator_approval_record_id, creator_approval_version,
	    creator_approval_revision, approval_record_id, approved_by,
	    approved_at_utc, public_announcement_revision, updated_at_utc
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(pool_id) DO UPDATE SET
	    operation_id = excluded.operation_id,
	    manifest_core_digest = excluded.manifest_core_digest,
	    reviewed_distribution_artifact_digest = excluded.reviewed_distribution_artifact_digest,
	    creator_account_id = excluded.creator_account_id,
	    creator_approval_record_id = excluded.creator_approval_record_id,
	    creator_approval_version = excluded.creator_approval_version,
	    creator_approval_revision = excluded.creator_approval_revision,
	    approval_record_id = excluded.approval_record_id,
	    approved_by = excluded.approved_by,
	    approved_at_utc = excluded.approved_at_utc,
	    public_announcement_revision = excluded.public_announcement_revision,
	    updated_at_utc = excluded.updated_at_utc`,
			approval.PoolID,
			approval.OperationID,
			approval.ManifestCoreDigest,
			approval.ReviewedDistributionDigest,
			approval.CreatorAccountID,
			approval.CreatorApprovalRecordID,
			approval.CreatorApprovalVersion,
			approval.CreatorApprovalRevision,
			approval.ApprovalRecordID,
			approval.ApprovedBy,
			approval.ApprovedAtUTC.Format(time.RFC3339Nano),
			approval.PublicAnnouncementRevision,
			approval.UpdatedAtUTC.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return PublicAnnouncementApproval{}, err
	}
	return approval, nil
}

func (s *Store) PublicAnnouncementApproval(ctx context.Context, poolID string) (PublicAnnouncementApproval, bool, error) {
	if s == nil || s.db == nil {
		return PublicAnnouncementApproval{}, false, ErrStoreClosed
	}
	return publicAnnouncementApprovalFromQueryer(ctx, s.db, strings.TrimSpace(poolID))
}

func (s *Store) PublicAnnouncementHistory(ctx context.Context, poolID string) ([]PublicAnnouncementApproval, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	return publicAnnouncementHistoryFromQueryer(ctx, s.db, strings.TrimSpace(poolID))
}

func (s *Store) publicAnnouncementApprovals(ctx context.Context) (map[string]PublicAnnouncementApproval, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	return publicAnnouncementApprovalsFromQueryer(ctx, s.db)
}

func operationIDExists(ctx context.Context, q eventQueryer, operationID string) (bool, error) {
	operationID = strings.TrimSpace(operationID)
	if operationID == "" {
		return false, nil
	}
	for _, query := range []string{
		`SELECT 1 FROM trustpool_events WHERE operation_id = ? LIMIT 1`,
		`SELECT 1 FROM trustpool_root_registration_nonces WHERE operation_id = ? LIMIT 1`,
		`SELECT 1 FROM trustpool_manifest_acceptances WHERE operation_id = ? LIMIT 1`,
		`SELECT 1 FROM trustpool_manifest_acceptance_high_water WHERE operation_id = ? LIMIT 1`,
		`SELECT 1 FROM trustpool_reviewed_distribution_artifact_history WHERE operation_id = ? LIMIT 1`,
		`SELECT 1 FROM trustpool_public_announcement_history WHERE operation_id = ? LIMIT 1`,
	} {
		rows, err := q.QueryContext(ctx, query, operationID)
		if err != nil {
			return false, err
		}
		found := rows.Next()
		if err := rows.Err(); err != nil {
			_ = rows.Close()
			return false, err
		}
		closeErr := rows.Close()
		if closeErr != nil {
			return false, closeErr
		}
		if found {
			return true, nil
		}
	}
	return false, nil
}

func insertManifestAcceptanceProjection(ctx context.Context, conn *sql.Conn, e DurableEvent) error {
	if e.EventType != EventManifestAccepted {
		return nil
	}
	p := manifestAcceptanceProjectionFromEvent(e)
	if _, err := conn.ExecContext(ctx, `
INSERT INTO trustpool_manifest_acceptances (
    pool_id, manifest_version, operation_id, accepted_at_utc, manifest_core_digest,
    root_issuer_key_id, root_issuer_public_key_fingerprint, manifest_signature,
    manifest_snapshot_sha256
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(pool_id, manifest_version) DO UPDATE SET
    operation_id = excluded.operation_id,
    accepted_at_utc = excluded.accepted_at_utc,
    manifest_core_digest = excluded.manifest_core_digest,
    root_issuer_key_id = excluded.root_issuer_key_id,
    root_issuer_public_key_fingerprint = excluded.root_issuer_public_key_fingerprint,
    manifest_signature = excluded.manifest_signature,
    manifest_snapshot_sha256 = excluded.manifest_snapshot_sha256`,
		p.PoolID,
		p.ManifestVersion,
		p.OperationID,
		p.AcceptedAtUTC.Format(time.RFC3339Nano),
		p.ManifestCoreDigest,
		p.RootIssuerKeyID,
		p.RootIssuerPublicKeyFP,
		p.ManifestSignature,
		p.ManifestSnapshotSHA256,
	); err != nil {
		return err
	}
	_, err := conn.ExecContext(ctx, `
INSERT INTO trustpool_manifest_acceptance_high_water (
    pool_id, manifest_version, operation_id, accepted_at_utc, manifest_core_digest,
    root_issuer_key_id, root_issuer_public_key_fingerprint, manifest_signature,
    manifest_snapshot_sha256
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(pool_id) DO UPDATE SET
    manifest_version = excluded.manifest_version,
    operation_id = excluded.operation_id,
    accepted_at_utc = excluded.accepted_at_utc,
    manifest_core_digest = excluded.manifest_core_digest,
    root_issuer_key_id = excluded.root_issuer_key_id,
    root_issuer_public_key_fingerprint = excluded.root_issuer_public_key_fingerprint,
    manifest_signature = excluded.manifest_signature,
    manifest_snapshot_sha256 = excluded.manifest_snapshot_sha256
WHERE excluded.manifest_version >= trustpool_manifest_acceptance_high_water.manifest_version`,
		p.PoolID,
		p.ManifestVersion,
		p.OperationID,
		p.AcceptedAtUTC.Format(time.RFC3339Nano),
		p.ManifestCoreDigest,
		p.RootIssuerKeyID,
		p.RootIssuerPublicKeyFP,
		p.ManifestSignature,
		p.ManifestSnapshotSHA256,
	)
	return err
}

func manifestAcceptanceProjectionFromEvent(e DurableEvent) ManifestAcceptanceProjection {
	return ManifestAcceptanceProjection{
		PoolID:                 e.PoolID,
		ManifestVersion:        e.ManifestVersion,
		OperationID:            e.OperationID,
		AcceptedAtUTC:          e.TimestampUTC.UTC(),
		ManifestCoreDigest:     e.ManifestCoreDigest,
		RootIssuerKeyID:        e.RootIssuerKeyID,
		RootIssuerPublicKeyFP:  e.RootIssuerPublicKeyFingerprint,
		ManifestSignature:      e.ManifestSignature,
		ManifestSnapshotSHA256: manifestSnapshotSHA256(e.ManifestSnapshot),
	}
}

func manifestAcceptanceProjectionsFromQueryer(ctx context.Context, q eventQueryer) (map[string]ManifestAcceptanceProjection, error) {
	rows, err := q.QueryContext(ctx, `
SELECT pool_id, manifest_version, operation_id, accepted_at_utc, manifest_core_digest,
       root_issuer_key_id, root_issuer_public_key_fingerprint, manifest_signature,
       manifest_snapshot_sha256
FROM trustpool_manifest_acceptances`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]ManifestAcceptanceProjection)
	for rows.Next() {
		p, err := scanManifestAcceptanceProjection(rows)
		if err != nil {
			return nil, err
		}
		out[manifestAcceptanceProjectionKey(p.PoolID, p.ManifestVersion)] = p
	}
	return out, rows.Err()
}

func manifestAcceptanceHighWaterFromQueryer(ctx context.Context, q eventQueryer) (map[string]ManifestAcceptanceProjection, error) {
	rows, err := q.QueryContext(ctx, `
SELECT pool_id, manifest_version, operation_id, accepted_at_utc, manifest_core_digest,
       root_issuer_key_id, root_issuer_public_key_fingerprint, manifest_signature,
       manifest_snapshot_sha256
FROM trustpool_manifest_acceptance_high_water`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]ManifestAcceptanceProjection)
	for rows.Next() {
		p, err := scanManifestAcceptanceProjection(rows)
		if err != nil {
			return nil, err
		}
		out[p.PoolID] = p
	}
	return out, rows.Err()
}

type manifestAcceptanceScanner interface {
	Scan(dest ...any) error
}

func scanManifestAcceptanceProjection(row manifestAcceptanceScanner) (ManifestAcceptanceProjection, error) {
	var p ManifestAcceptanceProjection
	var acceptedRaw string
	if err := row.Scan(
		&p.PoolID,
		&p.ManifestVersion,
		&p.OperationID,
		&acceptedRaw,
		&p.ManifestCoreDigest,
		&p.RootIssuerKeyID,
		&p.RootIssuerPublicKeyFP,
		&p.ManifestSignature,
		&p.ManifestSnapshotSHA256,
	); err != nil {
		return ManifestAcceptanceProjection{}, err
	}
	acceptedAt, err := time.Parse(time.RFC3339Nano, acceptedRaw)
	if err != nil {
		return ManifestAcceptanceProjection{}, fmt.Errorf("%w: manifest acceptance %s/%d accepted_at_utc: %v", ErrMalformedDurableEvent, p.PoolID, p.ManifestVersion, err)
	}
	p.AcceptedAtUTC = acceptedAt.UTC()
	return p, nil
}

func verifyManifestAcceptanceState(ctx context.Context, q eventQueryer, events []DurableEvent) error {
	projections, err := manifestAcceptanceProjectionsFromQueryer(ctx, q)
	if err != nil {
		return err
	}
	highWater, err := manifestAcceptanceHighWaterFromQueryer(ctx, q)
	if err != nil {
		return err
	}
	expected := make(map[string]ManifestAcceptanceProjection)
	latest := make(map[string]ManifestAcceptanceProjection)
	for _, e := range events {
		if e.EventType != EventManifestAccepted {
			continue
		}
		p := manifestAcceptanceProjectionFromEvent(e)
		expected[manifestAcceptanceProjectionKey(p.PoolID, p.ManifestVersion)] = p
		if cur, ok := latest[p.PoolID]; !ok || p.ManifestVersion > cur.ManifestVersion {
			latest[p.PoolID] = p
		}
	}
	if len(projections) != len(expected) {
		return fmt.Errorf("%w: manifest acceptance projection count %d != event count %d", ErrMalformedDurableEvent, len(projections), len(expected))
	}
	for key, want := range expected {
		got, ok := projections[key]
		if !ok {
			return fmt.Errorf("%w: missing manifest acceptance projection %s", ErrMalformedDurableEvent, key)
		}
		if !manifestAcceptanceProjectionEqual(got, want) {
			return fmt.Errorf("%w: manifest acceptance projection mismatch %s", ErrMalformedDurableEvent, key)
		}
	}
	if len(highWater) != len(latest) {
		return fmt.Errorf("%w: manifest acceptance high-water count %d != pool count %d", ErrMalformedDurableEvent, len(highWater), len(latest))
	}
	for poolID, want := range latest {
		got, ok := highWater[poolID]
		if !ok {
			return fmt.Errorf("%w: missing manifest acceptance high-water %s", ErrMalformedDurableEvent, poolID)
		}
		if !manifestAcceptanceProjectionEqual(got, want) {
			return fmt.Errorf("%w: manifest acceptance high-water mismatch %s", ErrMalformedDurableEvent, poolID)
		}
	}
	return nil
}

func manifestAcceptanceProjectionKey(poolID string, version uint64) string {
	return fmt.Sprintf("%s/%d", poolID, version)
}

func manifestAcceptanceProjectionEqual(a, b ManifestAcceptanceProjection) bool {
	return a.PoolID == b.PoolID &&
		a.ManifestVersion == b.ManifestVersion &&
		a.OperationID == b.OperationID &&
		a.AcceptedAtUTC.UTC().Equal(b.AcceptedAtUTC.UTC()) &&
		a.ManifestCoreDigest == b.ManifestCoreDigest &&
		a.RootIssuerKeyID == b.RootIssuerKeyID &&
		a.RootIssuerPublicKeyFP == b.RootIssuerPublicKeyFP &&
		a.ManifestSignature == b.ManifestSignature &&
		a.ManifestSnapshotSHA256 == b.ManifestSnapshotSHA256
}

func (s *Store) IssueRootRegistrationNonce(ctx context.Context, issue RootRegistrationNonceIssue) (RootRegistrationNonceRecord, error) {
	if s == nil || s.db == nil {
		return RootRegistrationNonceRecord{}, ErrStoreClosed
	}
	issue.OperationID = strings.TrimSpace(issue.OperationID)
	issue.CreatorAccountID = strings.TrimSpace(issue.CreatorAccountID)
	issue.ApprovalRecordID = strings.TrimSpace(issue.ApprovalRecordID)
	issue.CurrentApprovalVersion = strings.TrimSpace(issue.CurrentApprovalVersion)
	issue.LaunchEnvironment = strings.TrimSpace(issue.LaunchEnvironment)
	issue.Purpose = strings.TrimSpace(issue.Purpose)
	if issue.Purpose == "" {
		issue.Purpose = RootRegistrationPurposeDefault
	}
	if issue.OperationID == "" || issue.CreatorAccountID == "" || issue.ApprovalRecordID == "" || issue.CurrentApprovalVersion == "" ||
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
		OperationID:            issue.OperationID,
		CreatorAccountID:       issue.CreatorAccountID,
		ApprovalRecordID:       issue.ApprovalRecordID,
		CurrentApprovalVersion: issue.CurrentApprovalVersion,
		LaunchEnvironment:      issue.LaunchEnvironment,
		Purpose:                issue.Purpose,
		ExpiresAtUTC:           expires,
		IssuedAtUTC:            now,
	}
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if err := verifyManifestAcceptanceStateFromQueryer(ctx, conn); err != nil {
			return err
		}
		existing, ok, err := rootRegistrationNonceByOperationID(ctx, conn, issue.OperationID)
		if err != nil {
			return err
		}
		if ok {
			if rootRegistrationNonceMatchesIssue(existing, issue) {
				record = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		if used, err := operationIDExists(ctx, conn, issue.OperationID); err != nil {
			return err
		} else if used {
			return ErrConflictingOperationID
		}
		approval, ok, err := creatorApprovalFromQueryer(ctx, conn, issue.CreatorAccountID)
		if err != nil {
			return err
		}
		if !ok || !approval.ValidFor(issue.ApprovalRecordID, issue.CurrentApprovalVersion, issue.LaunchEnvironment, now) {
			return ErrCreatorApprovalGate
		}
		_, err = conn.ExecContext(ctx, `
	INSERT INTO trustpool_root_registration_nonces (
	    nonce, operation_id, creator_account_id, approval_record_id, current_approval_version,
	    launch_environment, purpose, expires_at_utc, issued_at_utc
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			record.Nonce,
			record.OperationID,
			record.CreatorAccountID,
			record.ApprovalRecordID,
			record.CurrentApprovalVersion,
			record.LaunchEnvironment,
			record.Purpose,
			record.ExpiresAtUTC.Format(time.RFC3339Nano),
			record.IssuedAtUTC.Format(time.RFC3339Nano),
		)
		if err != nil {
			existing, ok, lookupErr := rootRegistrationNonceByOperationID(ctx, conn, issue.OperationID)
			if lookupErr == nil && ok {
				if rootRegistrationNonceMatchesIssue(existing, issue) {
					record = existing
					return nil
				}
				return ErrConflictingOperationID
			}
		}
		return err
	})
	if err != nil {
		return RootRegistrationNonceRecord{}, err
	}
	return record, nil
}

type rootNonceQueryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func rootRegistrationNonceByOperationID(ctx context.Context, q rootNonceQueryer, operationID string) (RootRegistrationNonceRecord, bool, error) {
	if strings.TrimSpace(operationID) == "" {
		return RootRegistrationNonceRecord{}, false, nil
	}
	var record RootRegistrationNonceRecord
	var expiresRaw, issuedRaw string
	err := q.QueryRowContext(ctx, `
SELECT nonce, operation_id, creator_account_id, approval_record_id, current_approval_version,
       launch_environment, purpose, expires_at_utc, issued_at_utc
FROM trustpool_root_registration_nonces
WHERE operation_id = ?`, strings.TrimSpace(operationID)).Scan(
		&record.Nonce,
		&record.OperationID,
		&record.CreatorAccountID,
		&record.ApprovalRecordID,
		&record.CurrentApprovalVersion,
		&record.LaunchEnvironment,
		&record.Purpose,
		&expiresRaw,
		&issuedRaw,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return RootRegistrationNonceRecord{}, false, nil
	}
	if err != nil {
		return RootRegistrationNonceRecord{}, false, err
	}
	expiresAt, err := time.Parse(time.RFC3339Nano, expiresRaw)
	if err != nil {
		return RootRegistrationNonceRecord{}, false, ErrRootRegistrationNonce
	}
	issuedAt, err := time.Parse(time.RFC3339Nano, issuedRaw)
	if err != nil {
		return RootRegistrationNonceRecord{}, false, ErrRootRegistrationNonce
	}
	record.ExpiresAtUTC = expiresAt.UTC()
	record.IssuedAtUTC = issuedAt.UTC()
	return record, true, nil
}

func rootRegistrationNonceMatchesIssue(record RootRegistrationNonceRecord, issue RootRegistrationNonceIssue) bool {
	return record.OperationID == strings.TrimSpace(issue.OperationID) &&
		record.CreatorAccountID == strings.TrimSpace(issue.CreatorAccountID) &&
		record.ApprovalRecordID == strings.TrimSpace(issue.ApprovalRecordID) &&
		record.CurrentApprovalVersion == strings.TrimSpace(issue.CurrentApprovalVersion) &&
		record.LaunchEnvironment == strings.TrimSpace(issue.LaunchEnvironment) &&
		record.Purpose == strings.TrimSpace(issue.Purpose) &&
		record.ExpiresAtUTC.UTC().Equal(issue.ExpiresAtUTC.UTC())
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
	if hasSignedControlProof(e) {
		return ErrSignedControlProofPath
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

func (s *Store) ExistingEvent(ctx context.Context, operationID string) (DurableEvent, bool, error) {
	if s == nil || s.db == nil {
		return DurableEvent{}, false, ErrStoreClosed
	}
	operationID = strings.TrimSpace(operationID)
	if operationID == "" {
		return DurableEvent{}, false, nil
	}
	var raw string
	err := s.db.QueryRowContext(ctx, `SELECT payload_json FROM trustpool_events WHERE operation_id = ?`, operationID).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return DurableEvent{}, false, nil
	}
	if err != nil {
		return DurableEvent{}, false, err
	}
	var e DurableEvent
	if err := json.Unmarshal([]byte(raw), &e); err != nil {
		return DurableEvent{}, false, fmt.Errorf("%w: operation_id %q payload_json: %v", ErrMalformedDurableEvent, operationID, err)
	}
	if e.OperationID != operationID {
		return DurableEvent{}, false, fmt.Errorf("%w: operation_id column %q != payload %q", ErrMalformedDurableEvent, operationID, e.OperationID)
	}
	return e, true, nil
}

// AppendValidatedEvent appends e only if the full durable history still
// reconstructs after the append. This is the candidate/restrictive control-plane
// write primitive for admin/API surfaces: a syntactically valid event must not
// poison future boot replay with an invalid lifecycle or ordering transition,
// and raw active lifecycle publication is reserved for a future promotion gate.
func (s *Store) AppendValidatedEvent(ctx context.Context, e DurableEvent) (*ReconstructedState, DurableEvent, bool, error) {
	return s.appendValidatedEvent(ctx, e, false)
}

// AppendSignedLifecycleEvent is the only generic durable append path allowed to
// carry signed-control proof bytes. Callers must verify the signed control before
// calling this method; replay only persists the already-verified proof with the
// restrictive lifecycle event.
func (s *Store) AppendSignedLifecycleEvent(ctx context.Context, e DurableEvent) (*ReconstructedState, DurableEvent, bool, error) {
	if e.EventType != EventLifecycleChanged || e.Lifecycle == LifecycleActive || e.Lifecycle == "" || !hasSignedControlProof(e) {
		return nil, DurableEvent{}, false, ErrSignedControlProofPath
	}
	return s.appendValidatedEvent(ctx, e, true)
}

func (s *Store) appendValidatedEvent(ctx context.Context, e DurableEvent, allowSignedControlProof bool) (*ReconstructedState, DurableEvent, bool, error) {
	if s == nil || s.db == nil {
		return nil, DurableEvent{}, false, ErrStoreClosed
	}
	if hasSignedControlProof(e) && !allowSignedControlProof {
		return nil, DurableEvent{}, false, ErrSignedControlProofPath
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
		if err := verifyManifestAcceptanceState(ctx, conn, events); err != nil {
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
		if used, err := operationIDExists(ctx, conn, e.OperationID); err != nil {
			return err
		} else if used {
			return ErrConflictingOperationID
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
		if err := insertManifestAcceptanceProjection(ctx, conn, e); err != nil {
			return err
		}
		if err := verifyManifestAcceptanceState(ctx, conn, next); err != nil {
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

// PromotePool is the only durable write path allowed to append an active
// lifecycle event. It preflights the reconstructed pool state before writing,
// then replays the full event history including the activation/reactivation
// event before the transaction commits. Raw AppendValidatedEvent keeps
// rejecting active lifecycle events so operators cannot bypass these checks
// through the generic event API.
func (s *Store) PromotePool(ctx context.Context, e DurableEvent) (*ReconstructedState, DurableEvent, bool, error) {
	if s == nil || s.db == nil {
		return nil, DurableEvent{}, false, ErrStoreClosed
	}
	if hasSignedControlProof(e) {
		return nil, DurableEvent{}, false, ErrSignedControlProofPath
	}
	e.EventType = EventLifecycleChanged
	e.Lifecycle = LifecycleActive
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
		if err := verifyManifestAcceptanceState(ctx, conn, events); err != nil {
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
		if used, err := operationIDExists(ctx, conn, e.OperationID); err != nil {
			return err
		} else if used {
			return ErrConflictingOperationID
		}
		now := time.Now().UTC()
		preState, err := reconstructEventsWithApprovals(events, approvals, now)
		if err != nil {
			return err
		}
		if err := preState.validatePromotion(e, now); err != nil {
			return err
		}
		next := append(append([]DurableEvent(nil), events...), e)
		state, err := reconstructEventsWithApprovals(next, approvals, now)
		if err != nil {
			return err
		}
		payload, err := json.Marshal(e)
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
		if err := insertManifestAcceptanceProjection(ctx, conn, e); err != nil {
			return err
		}
		if err := verifyManifestAcceptanceState(ctx, conn, next); err != nil {
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
			return nil, fmt.Errorf("%w: row %d payload_json: %v", ErrMalformedDurableEvent, id, err)
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
		return CreatorApproval{}, fmt.Errorf("%w: creator approval %s creator_agreement_expires_at_utc: %v", ErrMalformedDurableEvent, approval.CreatorAccountID, err)
	}
	approval.CreatorAgreementGraceEndsAtUTC, err = time.Parse(time.RFC3339Nano, graceRaw)
	if err != nil {
		return CreatorApproval{}, fmt.Errorf("%w: creator approval %s creator_agreement_grace_ends_at_utc: %v", ErrMalformedDurableEvent, approval.CreatorAccountID, err)
	}
	approval.ApprovedAtUTC, err = time.Parse(time.RFC3339Nano, approvedRaw)
	if err != nil {
		return CreatorApproval{}, fmt.Errorf("%w: creator approval %s approved_at_utc: %v", ErrMalformedDurableEvent, approval.CreatorAccountID, err)
	}
	approval.UpdatedAtUTC, err = time.Parse(time.RFC3339Nano, updatedRaw)
	if err != nil {
		return CreatorApproval{}, fmt.Errorf("%w: creator approval %s updated_at_utc: %v", ErrMalformedDurableEvent, approval.CreatorAccountID, err)
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
	approval = normalizeCreatorApproval(approval)
	if err := validateCreatorApproval(approval); err != nil {
		return CreatorApproval{}, err
	}
	return approval, nil
}

func publicAnnouncementApprovalFromQueryer(ctx context.Context, q eventQueryer, poolID string) (PublicAnnouncementApproval, bool, error) {
	if poolID == "" {
		return PublicAnnouncementApproval{}, false, nil
	}
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       creator_account_id, creator_approval_record_id, creator_approval_version,
	       creator_approval_revision, approval_record_id, approved_by, approved_at_utc,
	       public_announcement_revision, updated_at_utc
	FROM trustpool_public_announcements
	WHERE pool_id = ?`, poolID)
	if err != nil {
		return PublicAnnouncementApproval{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return PublicAnnouncementApproval{}, false, rows.Err()
	}
	approval, err := scanPublicAnnouncementApproval(rows)
	if err != nil {
		return PublicAnnouncementApproval{}, false, err
	}
	if rows.Next() {
		return PublicAnnouncementApproval{}, false, fmt.Errorf("trustpool: duplicate public announcement approval for %q", poolID)
	}
	return approval, true, rows.Err()
}

func reviewedDistributionArtifactFromQueryer(ctx context.Context, q eventQueryer, poolID string) (ReviewedDistributionArtifact, bool, error) {
	if poolID == "" {
		return ReviewedDistributionArtifact{}, false, nil
	}
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       artifact_uri, claim_control_artifact_digest, reviewed_by, reviewed_at_utc,
	       review_revision, updated_at_utc
	FROM trustpool_reviewed_distribution_artifacts
	WHERE pool_id = ?`, poolID)
	if err != nil {
		return ReviewedDistributionArtifact{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return ReviewedDistributionArtifact{}, false, rows.Err()
	}
	artifact, err := scanReviewedDistributionArtifact(rows)
	if err != nil {
		return ReviewedDistributionArtifact{}, false, err
	}
	if rows.Next() {
		return ReviewedDistributionArtifact{}, false, fmt.Errorf("trustpool: duplicate reviewed distribution artifact for %q", poolID)
	}
	return artifact, true, rows.Err()
}

func reviewedDistributionArtifactsFromQueryer(ctx context.Context, q eventQueryer) (map[string]ReviewedDistributionArtifact, error) {
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       artifact_uri, claim_control_artifact_digest, reviewed_by, reviewed_at_utc,
	       review_revision, updated_at_utc
	FROM trustpool_reviewed_distribution_artifacts`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]ReviewedDistributionArtifact)
	for rows.Next() {
		artifact, err := scanReviewedDistributionArtifact(rows)
		if err != nil {
			return nil, err
		}
		out[artifact.PoolID] = artifact
	}
	return out, rows.Err()
}

func reviewedDistributionArtifactByOperationID(ctx context.Context, q eventQueryer, operationID string) (ReviewedDistributionArtifact, bool, error) {
	if operationID == "" {
		return ReviewedDistributionArtifact{}, false, nil
	}
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       artifact_uri, claim_control_artifact_digest, reviewed_by, reviewed_at_utc,
	       review_revision, updated_at_utc
	FROM trustpool_reviewed_distribution_artifact_history
	WHERE operation_id = ?`, operationID)
	if err != nil {
		return ReviewedDistributionArtifact{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return ReviewedDistributionArtifact{}, false, rows.Err()
	}
	artifact, err := scanReviewedDistributionArtifact(rows)
	if err != nil {
		return ReviewedDistributionArtifact{}, false, err
	}
	if rows.Next() {
		return ReviewedDistributionArtifact{}, false, fmt.Errorf("trustpool: duplicate reviewed distribution artifact operation %q", operationID)
	}
	return artifact, true, rows.Err()
}

func reviewedDistributionArtifactHistoryFromQueryer(ctx context.Context, q eventQueryer, poolID string) ([]ReviewedDistributionArtifact, error) {
	if poolID == "" {
		return nil, nil
	}
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       artifact_uri, claim_control_artifact_digest, reviewed_by, reviewed_at_utc,
	       review_revision, updated_at_utc
	FROM trustpool_reviewed_distribution_artifact_history
	WHERE pool_id = ?
	ORDER BY id`, poolID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ReviewedDistributionArtifact, 0)
	for rows.Next() {
		artifact, err := scanReviewedDistributionArtifact(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, artifact)
	}
	return out, rows.Err()
}

func publicAnnouncementApprovalsFromQueryer(ctx context.Context, q eventQueryer) (map[string]PublicAnnouncementApproval, error) {
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       creator_account_id, creator_approval_record_id, creator_approval_version,
	       creator_approval_revision, approval_record_id, approved_by, approved_at_utc,
	       public_announcement_revision, updated_at_utc
	FROM trustpool_public_announcements`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]PublicAnnouncementApproval)
	for rows.Next() {
		approval, err := scanPublicAnnouncementApproval(rows)
		if err != nil {
			return nil, err
		}
		out[approval.PoolID] = approval
	}
	return out, rows.Err()
}

func publicAnnouncementApprovalByOperationID(ctx context.Context, q eventQueryer, operationID string) (PublicAnnouncementApproval, bool, error) {
	if operationID == "" {
		return PublicAnnouncementApproval{}, false, nil
	}
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       creator_account_id, creator_approval_record_id, creator_approval_version,
	       creator_approval_revision, approval_record_id, approved_by, approved_at_utc,
	       public_announcement_revision, updated_at_utc
	FROM trustpool_public_announcement_history
	WHERE operation_id = ?`, operationID)
	if err != nil {
		return PublicAnnouncementApproval{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return PublicAnnouncementApproval{}, false, rows.Err()
	}
	approval, err := scanPublicAnnouncementApproval(rows)
	if err != nil {
		return PublicAnnouncementApproval{}, false, err
	}
	if rows.Next() {
		return PublicAnnouncementApproval{}, false, fmt.Errorf("trustpool: duplicate public announcement operation %q", operationID)
	}
	return approval, true, rows.Err()
}

func publicAnnouncementHistoryFromQueryer(ctx context.Context, q eventQueryer, poolID string) ([]PublicAnnouncementApproval, error) {
	if poolID == "" {
		return nil, nil
	}
	rows, err := q.QueryContext(ctx, `
	SELECT operation_id, pool_id, manifest_core_digest, reviewed_distribution_artifact_digest,
	       creator_account_id, creator_approval_record_id, creator_approval_version,
	       creator_approval_revision, approval_record_id, approved_by, approved_at_utc,
	       public_announcement_revision, updated_at_utc
	FROM trustpool_public_announcement_history
	WHERE pool_id = ?
	ORDER BY id`, poolID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]PublicAnnouncementApproval, 0)
	for rows.Next() {
		approval, err := scanPublicAnnouncementApproval(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, approval)
	}
	return out, rows.Err()
}

type publicAnnouncementApprovalScanner interface {
	Scan(dest ...any) error
}

type reviewedDistributionArtifactScanner interface {
	Scan(dest ...any) error
}

func scanPublicAnnouncementApproval(row publicAnnouncementApprovalScanner) (PublicAnnouncementApproval, error) {
	var approval PublicAnnouncementApproval
	var approvedRaw, updatedRaw string
	if err := row.Scan(
		&approval.OperationID,
		&approval.PoolID,
		&approval.ManifestCoreDigest,
		&approval.ReviewedDistributionDigest,
		&approval.CreatorAccountID,
		&approval.CreatorApprovalRecordID,
		&approval.CreatorApprovalVersion,
		&approval.CreatorApprovalRevision,
		&approval.ApprovalRecordID,
		&approval.ApprovedBy,
		&approvedRaw,
		&approval.PublicAnnouncementRevision,
		&updatedRaw,
	); err != nil {
		return PublicAnnouncementApproval{}, err
	}
	var err error
	approval.ApprovedAtUTC, err = time.Parse(time.RFC3339Nano, approvedRaw)
	if err != nil {
		return PublicAnnouncementApproval{}, fmt.Errorf("%w: public announcement %s approved_at_utc: %v", ErrMalformedDurableEvent, approval.PoolID, err)
	}
	approval.UpdatedAtUTC, err = time.Parse(time.RFC3339Nano, updatedRaw)
	if err != nil {
		return PublicAnnouncementApproval{}, fmt.Errorf("%w: public announcement %s updated_at_utc: %v", ErrMalformedDurableEvent, approval.PoolID, err)
	}
	approval = normalizePublicAnnouncementApproval(approval)
	if err := validateScannedPublicAnnouncementApproval(approval); err != nil {
		return PublicAnnouncementApproval{}, err
	}
	return approval, nil
}

func scanReviewedDistributionArtifact(row reviewedDistributionArtifactScanner) (ReviewedDistributionArtifact, error) {
	var artifact ReviewedDistributionArtifact
	var reviewedRaw, updatedRaw string
	if err := row.Scan(
		&artifact.OperationID,
		&artifact.PoolID,
		&artifact.ManifestCoreDigest,
		&artifact.ReviewedDistributionDigest,
		&artifact.ArtifactURI,
		&artifact.ClaimControlDigest,
		&artifact.ReviewedBy,
		&reviewedRaw,
		&artifact.ReviewRevision,
		&updatedRaw,
	); err != nil {
		return ReviewedDistributionArtifact{}, err
	}
	var err error
	artifact.ReviewedAtUTC, err = time.Parse(time.RFC3339Nano, reviewedRaw)
	if err != nil {
		return ReviewedDistributionArtifact{}, fmt.Errorf("%w: reviewed distribution artifact %s reviewed_at_utc: %v", ErrMalformedDurableEvent, artifact.PoolID, err)
	}
	artifact.UpdatedAtUTC, err = time.Parse(time.RFC3339Nano, updatedRaw)
	if err != nil {
		return ReviewedDistributionArtifact{}, fmt.Errorf("%w: reviewed distribution artifact %s updated_at_utc: %v", ErrMalformedDurableEvent, artifact.PoolID, err)
	}
	artifact = normalizeReviewedDistributionArtifact(artifact)
	if err := validateReviewedDistributionArtifact(artifact); err != nil {
		return ReviewedDistributionArtifact{}, err
	}
	return artifact, nil
}

func (s *Store) Reconstruct(ctx context.Context) (*ReconstructedState, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	var state *ReconstructedState
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		events, err := eventsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if err := verifyManifestAcceptanceState(ctx, conn, events); err != nil {
			return err
		}
		approvals, err := creatorApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		publicAnnouncements, err := publicAnnouncementApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		reviewedArtifacts, err := reviewedDistributionArtifactsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		state, err = reconstructEventsWithApprovalsAndPublicAnnouncements(events, approvals, publicAnnouncements, reviewedArtifacts, time.Now().UTC())
		return err
	})
	if err != nil {
		return nil, err
	}
	return state, nil
}

// ReconstructedState is the coordinator's query/admin view after durable replay.
type ReconstructedState struct {
	Pools               map[string]*ReconstructedPoolState
	CreatorApprovals    map[string]CreatorApproval
	PublicAnnouncements map[string]PublicAnnouncementApproval
	ReviewedArtifacts   map[string]ReviewedDistributionArtifact
	RouteGateCheckedAt  time.Time
	Revision            uint64
	rootNonces          map[string]string
}

type ReconstructedPoolState struct {
	PoolID                       string
	CreatorAccountID             string
	ApprovalRecordID             string
	Lifecycle                    string
	LifecycleReason              string
	MinBinaryVersion             string
	ManifestVersion              uint64
	ManifestCoreDigest           string
	ManifestSnapshot             string
	ManifestMinEligibleMembers   uint64
	ManifestMinBinaryVersion     string
	ManifestModelAllowlist       []string
	ManifestRetentionPolicyID    string
	ManifestSplitExecutionStatus string
	RootIssuer                   *ReconstructedRootIssuer
	Members                      map[string]bool
	Revoked                      map[string]bool
	BuyerAccounts                map[string]bool
	Generation                   uint64
	RouteableGeneration          uint64
	PubliclyAnnounced            bool
	PublicVisibilityGeneration   uint64
	PublicAnnouncementApprovalID string
	PublicReviewedArtifactDigest string
	LastEventAtUTC               time.Time
	CreatorGateReason            string
	CreatorGateExpiresAtUTC      time.Time
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
	return reconstructEventsWithApprovalsAndPublicAnnouncements(events, approvals, nil, nil, gateAt)
}

func reconstructEventsWithApprovalsAndPublicAnnouncements(events []DurableEvent, approvals map[string]CreatorApproval, publicAnnouncements map[string]PublicAnnouncementApproval, reviewedArtifacts map[string]ReviewedDistributionArtifact, gateAt time.Time) (*ReconstructedState, error) {
	state := &ReconstructedState{Pools: make(map[string]*ReconstructedPoolState), rootNonces: make(map[string]string)}
	if approvals != nil {
		state.CreatorApprovals = make(map[string]CreatorApproval, len(approvals))
		for k, v := range approvals {
			state.CreatorApprovals[k] = v
		}
		state.RouteGateCheckedAt = gateAt.UTC()
	}
	if publicAnnouncements != nil {
		state.PublicAnnouncements = make(map[string]PublicAnnouncementApproval, len(publicAnnouncements))
		for k, v := range publicAnnouncements {
			state.PublicAnnouncements[k] = v
		}
	}
	if reviewedArtifacts != nil {
		state.ReviewedArtifacts = make(map[string]ReviewedDistributionArtifact, len(reviewedArtifacts))
		for k, v := range reviewedArtifacts {
			state.ReviewedArtifacts[k] = v
		}
	}
	seenOps := make(map[string]int)
	for i, e := range events {
		if err := validateEvent(e); err != nil {
			if errors.Is(err, ErrProhibitedPromiseClaim) {
				return nil, fmt.Errorf("%w: replay event %d: %w", ErrMalformedDurableEvent, i+1, err)
			}
			return nil, fmt.Errorf("%w: replay event %d: %v", ErrMalformedDurableEvent, i+1, err)
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
	state.applyPublicVisibilityGates()
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
		prevDigest, core, err := VerifyManifestAcceptedEvent(e, *p.RootIssuer)
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
		currentFloor := policyMinBinaryVersion(p)
		if currentFloor != "" && core.MinBinaryVersion == "" {
			return nil, fmt.Errorf("%w: event %d clears min binary version for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if currentFloor != "" && core.MinBinaryVersion != "" {
			cmp, ok := versionfloor.Compare(core.MinBinaryVersion, currentFloor)
			if !ok || cmp < 0 {
				return nil, fmt.Errorf("%w: event %d lowers min binary version from %q to %q for pool %q", ErrMalformedDurableEvent, index, currentFloor, core.MinBinaryVersion, e.PoolID)
			}
		}
		p.ManifestVersion = e.ManifestVersion
		p.ManifestCoreDigest = e.ManifestCoreDigest
		p.ManifestSnapshot = e.ManifestSnapshot
		p.ManifestMinEligibleMembers = core.MinEligibleMembers
		p.ManifestMinBinaryVersion = core.MinBinaryVersion
		p.ManifestModelAllowlist = append([]string(nil), core.ModelAllowlist...)
		p.ManifestRetentionPolicyID = core.RetentionPolicyID
		p.ManifestSplitExecutionStatus = core.SplitExecutionStatus
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
		currentFloor := policyMinBinaryVersion(p)
		if e.MinBinaryVersion == "" && currentFloor != "" {
			return nil, fmt.Errorf("%w: event %d clears min binary version for pool %q", ErrMalformedDurableEvent, index, e.PoolID)
		}
		if currentFloor != "" && e.MinBinaryVersion != "" {
			cmp, ok := versionfloor.Compare(e.MinBinaryVersion, currentFloor)
			if !ok || cmp < 0 {
				return nil, fmt.Errorf("%w: event %d lowers min binary version from %q to %q for pool %q", ErrMalformedDurableEvent, index, currentFloor, e.MinBinaryVersion, e.PoolID)
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

func (s *ReconstructedState) applyPublicVisibilityGates() {
	if s == nil {
		return
	}
	for _, p := range s.Pools {
		p.PubliclyAnnounced = false
		p.PublicVisibilityGeneration = p.EffectiveGeneration()
		p.PublicAnnouncementApprovalID = ""
		p.PublicReviewedArtifactDigest = ""
		approval, ok := s.PublicAnnouncements[p.PoolID]
		if !ok {
			continue
		}
		artifact, artifactOK := s.ReviewedArtifacts[p.PoolID]
		p.PublicVisibilityGeneration = p.EffectiveGeneration() + approval.PublicAnnouncementRevision
		if artifactOK {
			p.PublicVisibilityGeneration += artifact.ReviewRevision
		}
		if approval, ok := matchingPublicAnnouncement(s, p); ok {
			p.PubliclyAnnounced = true
			p.PublicAnnouncementApprovalID = approval.ApprovalRecordID
			p.PublicReviewedArtifactDigest = approval.ReviewedDistributionDigest
			continue
		}
		p.PublicVisibilityGeneration++
	}
}

func currentPublicAnnouncementBinding(state *ReconstructedState, p *ReconstructedPoolState) (PublicAnnouncementApproval, bool) {
	if state == nil || p == nil || p.CreatorGateReason != "" || state.CreatorApprovals == nil {
		return PublicAnnouncementApproval{}, false
	}
	approval, ok := state.CreatorApprovals[p.CreatorAccountID]
	if !ok {
		return PublicAnnouncementApproval{}, false
	}
	version := approval.CurrentApprovalVersion
	environment := approval.AllowedLaunchEnvironment
	if p.RootIssuer != nil {
		version = p.RootIssuer.CurrentApprovalVersion
		environment = p.RootIssuer.LaunchEnvironment
	}
	if !approval.ValidFor(p.ApprovalRecordID, version, environment, state.RouteGateCheckedAt) {
		return PublicAnnouncementApproval{}, false
	}
	return PublicAnnouncementApproval{
		CreatorAccountID:        p.CreatorAccountID,
		CreatorApprovalRecordID: p.ApprovalRecordID,
		CreatorApprovalVersion:  version,
		CreatorApprovalRevision: approval.ApprovalRevision,
	}, true
}

func publicAnnouncementLaunchAllowed(p *ReconstructedPoolState) bool {
	if p == nil || p.RootIssuer == nil {
		return false
	}
	environment := strings.TrimSpace(p.RootIssuer.LaunchEnvironment)
	return environment != "" && environment != promotionLaunchEnvironmentCandidate
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

func (s *ReconstructedState) validatePromotion(e DurableEvent, now time.Time) error {
	if s == nil {
		return PromotionPreconditionError{Reason: "state_unavailable"}
	}
	if e.EventType != EventLifecycleChanged || e.Lifecycle != LifecycleActive {
		return PromotionPreconditionError{Reason: "invalid_promotion_event"}
	}
	p := s.Pools[e.PoolID]
	if p == nil {
		return PromotionPreconditionError{Reason: "pool_not_found"}
	}
	if p.Lifecycle != LifecycleCreated && p.Lifecycle != LifecyclePaused {
		return PromotionPreconditionError{Reason: "lifecycle_" + p.Lifecycle}
	}
	if p.RootIssuer == nil {
		return PromotionPreconditionError{Reason: "root_issuer_missing"}
	}
	if p.RootIssuer.LaunchEnvironment != promotionLaunchEnvironmentCandidate {
		return PromotionPreconditionError{Reason: "launch_environment_not_candidate"}
	}
	if p.ManifestVersion == 0 || p.ManifestCoreDigest == "" {
		return PromotionPreconditionError{Reason: "manifest_missing"}
	}
	if p.CreatorGateReason != "" {
		return PromotionPreconditionError{Reason: p.CreatorGateReason}
	}
	if len(p.BuyerAccounts) == 0 {
		return PromotionPreconditionError{Reason: "buyer_authorization_missing"}
	}
	if nonRevokedMemberCountFromMaps(p.Members, p.Revoked) < policyMinEligibleMembers(p) {
		return PromotionPreconditionError{Reason: "member_missing"}
	}
	if !poolManifestRetentionPolicyResolved(p) {
		return PromotionPreconditionError{Reason: "retention_policy_unresolved"}
	}
	if s.CreatorApprovals != nil {
		approval, ok := s.CreatorApprovals[p.CreatorAccountID]
		if !ok {
			return PromotionPreconditionError{Reason: "creator_approval_missing"}
		}
		if !approval.ValidFor(p.ApprovalRecordID, p.RootIssuer.CurrentApprovalVersion, p.RootIssuer.LaunchEnvironment, now) {
			return PromotionPreconditionError{Reason: approval.InvalidReason(p.ApprovalRecordID, p.RootIssuer.CurrentApprovalVersion, p.RootIssuer.LaunchEnvironment, now)}
		}
	}
	return nil
}

func nonRevokedMemberCountFromMaps(members, revoked map[string]bool) int {
	var n int
	for id := range members {
		if !revoked[id] {
			n++
		}
	}
	return n
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

func hasSignedControlProof(e DurableEvent) bool {
	return strings.TrimSpace(e.SignedControl) != "" || strings.TrimSpace(e.ControlSignatures) != ""
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
		routeable, _ := poolRouteability(p)
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
			MinBinaryVersion:  policyMinBinaryVersion(p),
			ModelAllowlist:    append([]string(nil), p.ManifestModelAllowlist...),
			Routeable:         routeable,
			Generation:        p.RouteableSnapshotGeneration(),
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

func (p *ReconstructedPoolState) RouteableSnapshotGeneration() uint64 {
	generation := p.EffectiveGeneration()
	if p != nil && p.Lifecycle == LifecycleActive {
		if routeable, _ := poolRouteability(p); !routeable {
			generation++
		}
	}
	return generation
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
	if err := ValidatePromiseClaimsText(e.PoolID); err != nil {
		return err
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
		if err := ValidatePromiseClaimsText(
			e.CreatorAccountID,
			e.ApprovalRecordID,
			e.CurrentApprovalVersion,
			e.RootIssuerKeyID,
			e.ManifestAuthorityRootKeyID,
			e.LaunchEnvironment,
		); err != nil {
			return err
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
		raw, err := canonicalBase64(e.ManifestSnapshot)
		if err != nil {
			return err
		}
		if utf8.Valid(raw) {
			if err := ValidatePromiseClaimsText(string(raw)); err != nil {
				return err
			}
		}
		core, err := acceptedPolicyCoreFromManifestSnapshot(e)
		if err != nil {
			return err
		}
		if err := validateCandidatePolicyCoreClaims(core); err != nil {
			return err
		}
	case EventLifecycleChanged:
		if !validLifecycle(e.Lifecycle) {
			return fmt.Errorf("invalid lifecycle %q", e.Lifecycle)
		}
		if err := ValidatePromiseClaimsText(e.Reason, e.SignedControl, e.ControlSignatures); err != nil {
			return err
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
		return to == LifecycleActive || to == LifecycleDraining || to == LifecycleRetired
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
	if err := ValidatePromiseClaimsText(
		a.CreatorAccountID,
		a.ApprovalRecordID,
		a.CurrentApprovalVersion,
		a.PublicDisplayName,
		a.AllowedProductCategory,
		a.DataRetentionCategory,
		a.AllowedLaunchEnvironment,
		a.CreatorAgreementID,
		a.CreatorAgreementVersion,
		a.PricingScheduleID,
		a.PricingScheduleVersion,
	); err != nil {
		return err
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

func normalizePublicAnnouncementApproval(a PublicAnnouncementApproval) PublicAnnouncementApproval {
	a.OperationID = strings.TrimSpace(a.OperationID)
	a.PoolID = strings.TrimSpace(a.PoolID)
	a.ManifestCoreDigest = strings.TrimSpace(strings.ToLower(a.ManifestCoreDigest))
	a.ReviewedDistributionDigest = strings.TrimSpace(strings.ToLower(a.ReviewedDistributionDigest))
	a.CreatorAccountID = strings.TrimSpace(a.CreatorAccountID)
	a.CreatorApprovalRecordID = strings.TrimSpace(a.CreatorApprovalRecordID)
	a.CreatorApprovalVersion = strings.TrimSpace(a.CreatorApprovalVersion)
	a.ApprovalRecordID = strings.TrimSpace(a.ApprovalRecordID)
	a.ApprovedBy = strings.TrimSpace(a.ApprovedBy)
	a.ApprovedAtUTC = a.ApprovedAtUTC.UTC()
	a.UpdatedAtUTC = a.UpdatedAtUTC.UTC()
	return a
}

func normalizeReviewedDistributionArtifact(a ReviewedDistributionArtifact) ReviewedDistributionArtifact {
	a.OperationID = strings.TrimSpace(a.OperationID)
	a.PoolID = strings.TrimSpace(a.PoolID)
	a.ManifestCoreDigest = strings.TrimSpace(strings.ToLower(a.ManifestCoreDigest))
	a.ReviewedDistributionDigest = strings.TrimSpace(strings.ToLower(a.ReviewedDistributionDigest))
	a.ArtifactURI = strings.TrimSpace(a.ArtifactURI)
	a.ClaimControlDigest = strings.TrimSpace(strings.ToLower(a.ClaimControlDigest))
	a.ReviewedBy = strings.TrimSpace(a.ReviewedBy)
	a.ReviewedAtUTC = a.ReviewedAtUTC.UTC()
	a.UpdatedAtUTC = a.UpdatedAtUTC.UTC()
	return a
}

func validatePublicAnnouncementApproval(a PublicAnnouncementApproval) error {
	if a.OperationID == "" || a.PoolID == "" || a.ManifestCoreDigest == "" || a.ReviewedDistributionDigest == "" ||
		a.ApprovalRecordID == "" || a.ApprovedBy == "" || a.ApprovedAtUTC.IsZero() {
		return ErrPublicAnnouncementGate
	}
	if !validSHA256Hex(a.ManifestCoreDigest) || !validSHA256Hex(a.ReviewedDistributionDigest) {
		return ErrPublicAnnouncementGate
	}
	if err := ValidatePromiseClaimsText(a.OperationID, a.PoolID, a.ApprovalRecordID, a.ApprovedBy); err != nil {
		return err
	}
	return nil
}

func validateReviewedDistributionArtifact(a ReviewedDistributionArtifact) error {
	if a.OperationID == "" || a.PoolID == "" || a.ManifestCoreDigest == "" || a.ReviewedDistributionDigest == "" ||
		a.ArtifactURI == "" || a.ClaimControlDigest == "" || a.ReviewedBy == "" || a.ReviewedAtUTC.IsZero() {
		return ErrPublicAnnouncementGate
	}
	if !validSHA256Hex(a.ManifestCoreDigest) || !validSHA256Hex(a.ReviewedDistributionDigest) || !validSHA256Hex(a.ClaimControlDigest) {
		return ErrPublicAnnouncementGate
	}
	if err := ValidatePromiseClaimsText(a.OperationID, a.PoolID, a.ArtifactURI, a.ReviewedBy); err != nil {
		return err
	}
	return nil
}

func validateScannedPublicAnnouncementApproval(a PublicAnnouncementApproval) error {
	if a.PoolID == "" || a.ManifestCoreDigest == "" || a.ApprovalRecordID == "" || a.ApprovedBy == "" || a.ApprovedAtUTC.IsZero() {
		return ErrPublicAnnouncementGate
	}
	if !validSHA256Hex(a.ManifestCoreDigest) {
		return ErrPublicAnnouncementGate
	}
	if a.ReviewedDistributionDigest != "" && !validSHA256Hex(a.ReviewedDistributionDigest) {
		return ErrPublicAnnouncementGate
	}
	if err := ValidatePromiseClaimsText(a.OperationID, a.PoolID, a.ApprovalRecordID, a.ApprovedBy); err != nil {
		return err
	}
	return nil
}

func validateStoredPublicAnnouncementApproval(a PublicAnnouncementApproval) error {
	if err := validatePublicAnnouncementApproval(a); err != nil {
		return err
	}
	if a.CreatorAccountID == "" || a.CreatorApprovalRecordID == "" || a.CreatorApprovalVersion == "" || a.CreatorApprovalRevision == 0 {
		return ErrPublicAnnouncementGate
	}
	if err := ValidatePromiseClaimsText(a.CreatorAccountID, a.CreatorApprovalRecordID, a.CreatorApprovalVersion); err != nil {
		return err
	}
	return nil
}

func publicAnnouncementApprovalMatchesOperation(stored, input PublicAnnouncementApproval) bool {
	stored = normalizePublicAnnouncementApproval(stored)
	input = normalizePublicAnnouncementApproval(input)
	return stored.OperationID == input.OperationID &&
		stored.PoolID == input.PoolID &&
		stored.ManifestCoreDigest == input.ManifestCoreDigest &&
		stored.ReviewedDistributionDigest == input.ReviewedDistributionDigest &&
		stored.ApprovalRecordID == input.ApprovalRecordID &&
		stored.ApprovedBy == input.ApprovedBy &&
		stored.ApprovedAtUTC.Equal(input.ApprovedAtUTC)
}

func reviewedDistributionArtifactMatchesOperation(stored, input ReviewedDistributionArtifact) bool {
	stored = normalizeReviewedDistributionArtifact(stored)
	input = normalizeReviewedDistributionArtifact(input)
	return stored.OperationID == input.OperationID &&
		stored.PoolID == input.PoolID &&
		stored.ManifestCoreDigest == input.ManifestCoreDigest &&
		stored.ReviewedDistributionDigest == input.ReviewedDistributionDigest &&
		stored.ArtifactURI == input.ArtifactURI &&
		stored.ClaimControlDigest == input.ClaimControlDigest &&
		stored.ReviewedBy == input.ReviewedBy &&
		stored.ReviewedAtUTC.Equal(input.ReviewedAtUTC)
}

func samePublicAnnouncementApprovalExceptRevision(a, b PublicAnnouncementApproval) bool {
	a = normalizePublicAnnouncementApproval(a)
	b = normalizePublicAnnouncementApproval(b)
	a.PublicAnnouncementRevision = 0
	b.PublicAnnouncementRevision = 0
	a.UpdatedAtUTC = time.Time{}
	b.UpdatedAtUTC = time.Time{}
	return a == b
}

func sameReviewedDistributionArtifactExceptRevision(a, b ReviewedDistributionArtifact) bool {
	a = normalizeReviewedDistributionArtifact(a)
	b = normalizeReviewedDistributionArtifact(b)
	a.OperationID = ""
	b.OperationID = ""
	a.ReviewRevision = 0
	b.ReviewRevision = 0
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
