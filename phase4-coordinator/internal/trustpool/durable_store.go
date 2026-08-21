package trustpool

import (
	"context"
	"database/sql"
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
)

// DurableEvent is one append-only SPEC-043 pool control-plane fact. It is
// intentionally narrow for the first MVP slice: it records enough to rebuild
// routeable pool membership, lifecycle, creator ownership for accepted pools,
// buyer scopes, and manifest labels without implementing the creator approval
// store or creator-admin API yet.
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
}

// Store persists DurableEvent rows in the coordinator SQLite DB.
type Store struct {
	db *sql.DB
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
    reason TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trustpool_events_pool_id ON trustpool_events(pool_id, id);
CREATE INDEX IF NOT EXISTS idx_trustpool_events_creator ON trustpool_events(creator_account_id, id);
CREATE INDEX IF NOT EXISTS idx_trustpool_events_event_type ON trustpool_events(event_type, id);
`)
	if err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "trustpool_events", "approval_record_id", "TEXT"); err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `CREATE INDEX IF NOT EXISTS idx_trustpool_events_approval ON trustpool_events(approval_record_id, id)`)
	return err
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
    manifest_core_digest, reason, payload_json
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
			reconstructed, err = ReconstructEvents(events)
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
		payload, err := json.Marshal(e)
		if err != nil {
			return err
		}
		next := append(append([]DurableEvent(nil), events...), e)
		state, err := ReconstructEvents(next)
		if err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO trustpool_events (
    operation_id, ts_utc, event_type, pool_id, creator_account_id, approval_record_id, provider_id,
    buyer_account_id, lifecycle, min_binary_version, manifest_version,
    manifest_core_digest, reason, payload_json
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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

func (s *Store) Reconstruct(ctx context.Context) (*ReconstructedState, error) {
	events, err := s.Events(ctx)
	if err != nil {
		return nil, err
	}
	return ReconstructEvents(events)
}

// ReconstructedState is the coordinator's query/admin view after durable replay.
type ReconstructedState struct {
	Pools    map[string]*ReconstructedPoolState
	Revision uint64
}

type ReconstructedPoolState struct {
	PoolID             string
	CreatorAccountID   string
	ApprovalRecordID   string
	Lifecycle          string
	LifecycleReason    string
	MinBinaryVersion   string
	ManifestVersion    uint64
	ManifestCoreDigest string
	Members            map[string]bool
	Revoked            map[string]bool
	BuyerAccounts      map[string]bool
	Generation         uint64
	LastEventAtUTC     time.Time
}

func ReconstructEvents(events []DurableEvent) (*ReconstructedState, error) {
	state := &ReconstructedState{Pools: make(map[string]*ReconstructedPoolState)}
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
	state.Revision = uint64(len(events))
	return state, nil
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
	case EventManifestAccepted:
		if e.ManifestVersion <= p.ManifestVersion {
			return nil, fmt.Errorf("%w: event %d manifest version %d not newer than current %d for pool %q", ErrMalformedDurableEvent, index, e.ManifestVersion, p.ManifestVersion, e.PoolID)
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
		members := make([]string, 0, len(p.Members))
		if p.Lifecycle == LifecycleActive {
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
			PoolID:           p.PoolID,
			Members:          members,
			Revoked:          revoked,
			BuyerAccounts:    buyers,
			MinBinaryVersion: p.MinBinaryVersion,
			Routeable:        p.Lifecycle == LifecycleActive,
			Generation:       p.Generation,
		})
	}
	return out
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
	case EventManifestAccepted:
		if e.ManifestVersion == 0 || e.ManifestCoreDigest == "" {
			return fmt.Errorf("manifest_accepted requires manifest_version and manifest_core_digest")
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
