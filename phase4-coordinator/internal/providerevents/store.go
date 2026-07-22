package providerevents

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"
)

const defaultRetention = 14 * 24 * time.Hour

// Event is one redacted, durable provider connection lifecycle observation.
type Event struct {
	ID            int64     `json:"id"`
	ProviderID    string    `json:"provider_id"`
	SessionID     string    `json:"session_id,omitempty"`
	AttemptID     string    `json:"attempt_id,omitempty"`
	OccurredAt    time.Time `json:"occurred_at"`
	Kind          string    `json:"kind"`
	Outcome       string    `json:"outcome"`
	FailureReason string    `json:"failure_reason,omitempty"`
	AuthStage     string    `json:"auth_stage,omitempty"`
	MessageFamily string    `json:"message_family,omitempty"`
	BinaryVersion string    `json:"binary_version,omitempty"`
	CloseCode     int       `json:"close_code,omitempty"`
	CloseReason   string    `json:"close_reason,omitempty"`
	Diagnostic    string    `json:"diagnostic,omitempty"`
}

// LastKnown is the latest non-secret provider snapshot retained for offline
// operator inspect. Connected providers prefer live pool state; offline
// providers return this record plus recent events.
type LastKnown struct {
	ProviderID      string     `json:"provider_id"`
	AssignedID      string     `json:"assigned_id,omitempty"`
	BinaryVersion   string     `json:"binary_version,omitempty"`
	ModelID         string     `json:"model_id,omitempty"`
	State           string     `json:"state,omitempty"`
	AuthState       string     `json:"auth_state,omitempty"`
	ConnectedAt     *time.Time `json:"connected_at,omitempty"`
	LastHeartbeatAt *time.Time `json:"last_heartbeat_at,omitempty"`
	LastActivityAt  *time.Time `json:"last_activity_at,omitempty"`
	LastSeenAt      time.Time  `json:"last_seen_at"`
	RoutingEligible bool       `json:"routing_eligible"`
	Presence        string     `json:"presence,omitempty"` // connected|offline
}

// Store is the durable journal + last-known surface used by operator GETs.
type Store interface {
	Record(ctx context.Context, event Event) error
	UpsertLastKnown(ctx context.Context, snap LastKnown) error
	GetLastKnown(ctx context.Context, providerID string) (LastKnown, bool, error)
	ListLastKnown(ctx context.Context) ([]LastKnown, error)
	ListEvents(ctx context.Context, providerID string, limit int) ([]Event, error)
	Prune(ctx context.Context, olderThan time.Time) (int64, error)
}

// SQLiteStore persists events beside the coordinator request-log DB.
type SQLiteStore struct {
	db             *sql.DB
	retention      time.Duration
	perProviderCap int
	now            func() time.Time
}

// NewSQLiteStore migrates schema and returns a ready store.
func NewSQLiteStore(db *sql.DB) (*SQLiteStore, error) {
	if db == nil {
		return nil, fmt.Errorf("providerevents: db is required")
	}
	s := &SQLiteStore{
		db:             db,
		retention:      defaultRetention,
		perProviderCap: DefaultPerProviderCap,
		now:            func() time.Time { return time.Now().UTC() },
	}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *SQLiteStore) migrate(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS provider_connection_events (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	provider_id TEXT NOT NULL DEFAULT '',
	session_id TEXT NOT NULL DEFAULT '',
	attempt_id TEXT NOT NULL DEFAULT '',
	occurred_at_utc TEXT NOT NULL,
	kind TEXT NOT NULL,
	outcome TEXT NOT NULL,
	failure_reason TEXT NOT NULL DEFAULT '',
	auth_stage TEXT NOT NULL DEFAULT '',
	message_family TEXT NOT NULL DEFAULT '',
	binary_version TEXT NOT NULL DEFAULT '',
	close_code INTEGER NOT NULL DEFAULT 0,
	close_reason TEXT NOT NULL DEFAULT '',
	diagnostic TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_provider_connection_events_provider_time
	ON provider_connection_events(provider_id, occurred_at_utc DESC);
CREATE INDEX IF NOT EXISTS idx_provider_connection_events_time
	ON provider_connection_events(occurred_at_utc);

CREATE TABLE IF NOT EXISTS provider_last_known (
	provider_id TEXT PRIMARY KEY,
	assigned_id TEXT NOT NULL DEFAULT '',
	binary_version TEXT NOT NULL DEFAULT '',
	model_id TEXT NOT NULL DEFAULT '',
	state TEXT NOT NULL DEFAULT '',
	auth_state TEXT NOT NULL DEFAULT '',
	connected_at_utc TEXT NOT NULL DEFAULT '',
	last_heartbeat_at_utc TEXT NOT NULL DEFAULT '',
	last_activity_at_utc TEXT NOT NULL DEFAULT '',
	last_seen_at_utc TEXT NOT NULL,
	routing_eligible INTEGER NOT NULL DEFAULT 0
);
`)
	return err
}

func (s *SQLiteStore) Record(ctx context.Context, event Event) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("providerevents: store closed")
	}
	event = sanitizeEvent(event, s.now())
	_, err := s.db.ExecContext(ctx, `
INSERT INTO provider_connection_events (
	provider_id, session_id, attempt_id, occurred_at_utc, kind, outcome,
	failure_reason, auth_stage, message_family, binary_version,
	close_code, close_reason, diagnostic
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ProviderID,
		event.SessionID,
		event.AttemptID,
		event.OccurredAt.UTC().Format(time.RFC3339Nano),
		event.Kind,
		event.Outcome,
		event.FailureReason,
		event.AuthStage,
		event.MessageFamily,
		event.BinaryVersion,
		event.CloseCode,
		event.CloseReason,
		event.Diagnostic,
	)
	if err != nil {
		return err
	}
	// Best-effort retention: never fail the write path on prune errors.
	cutoff := s.now().Add(-s.retention)
	_, _ = s.Prune(ctx, cutoff)
	if event.ProviderID != "" {
		_ = s.enforcePerProviderCap(ctx, event.ProviderID)
	}
	return nil
}

func (s *SQLiteStore) enforcePerProviderCap(ctx context.Context, providerID string) error {
	var count int
	if err := s.db.QueryRowContext(ctx, `
SELECT COUNT(*) FROM provider_connection_events WHERE provider_id = ?`, providerID).Scan(&count); err != nil {
		return err
	}
	if count <= s.perProviderCap {
		return nil
	}
	excess := count - s.perProviderCap
	_, err := s.db.ExecContext(ctx, `
DELETE FROM provider_connection_events
WHERE id IN (
	SELECT id FROM provider_connection_events
	WHERE provider_id = ?
	ORDER BY occurred_at_utc ASC, id ASC
	LIMIT ?
)`, providerID, excess)
	return err
}

func (s *SQLiteStore) UpsertLastKnown(ctx context.Context, snap LastKnown) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("providerevents: store closed")
	}
	providerID := strings.TrimSpace(snap.ProviderID)
	if providerID == "" {
		return fmt.Errorf("providerevents: provider_id required")
	}
	if snap.LastSeenAt.IsZero() {
		snap.LastSeenAt = s.now()
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO provider_last_known (
	provider_id, assigned_id, binary_version, model_id, state, auth_state,
	connected_at_utc, last_heartbeat_at_utc, last_activity_at_utc,
	last_seen_at_utc, routing_eligible
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(provider_id) DO UPDATE SET
	assigned_id = excluded.assigned_id,
	binary_version = excluded.binary_version,
	model_id = excluded.model_id,
	state = excluded.state,
	auth_state = excluded.auth_state,
	connected_at_utc = excluded.connected_at_utc,
	last_heartbeat_at_utc = excluded.last_heartbeat_at_utc,
	last_activity_at_utc = excluded.last_activity_at_utc,
	last_seen_at_utc = excluded.last_seen_at_utc,
	routing_eligible = excluded.routing_eligible`,
		providerID,
		strings.TrimSpace(snap.AssignedID),
		RedactDiagnostic(snap.BinaryVersion, 64),
		RedactDiagnostic(snap.ModelID, 128),
		RedactDiagnostic(snap.State, 64),
		RedactDiagnostic(snap.AuthState, 64),
		formatOptionalTime(snap.ConnectedAt),
		formatOptionalTime(snap.LastHeartbeatAt),
		formatOptionalTime(snap.LastActivityAt),
		snap.LastSeenAt.UTC().Format(time.RFC3339Nano),
		boolToInt(snap.RoutingEligible),
	)
	return err
}

func (s *SQLiteStore) GetLastKnown(ctx context.Context, providerID string) (LastKnown, bool, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return LastKnown{}, false, nil
	}
	row := s.db.QueryRowContext(ctx, `
SELECT provider_id, assigned_id, binary_version, model_id, state, auth_state,
	connected_at_utc, last_heartbeat_at_utc, last_activity_at_utc,
	last_seen_at_utc, routing_eligible
FROM provider_last_known WHERE provider_id = ?`, providerID)
	snap, err := scanLastKnown(row)
	if err == sql.ErrNoRows {
		return LastKnown{}, false, nil
	}
	if err != nil {
		return LastKnown{}, false, err
	}
	return snap, true, nil
}

func (s *SQLiteStore) ListLastKnown(ctx context.Context) ([]LastKnown, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, assigned_id, binary_version, model_id, state, auth_state,
	connected_at_utc, last_heartbeat_at_utc, last_activity_at_utc,
	last_seen_at_utc, routing_eligible
FROM provider_last_known
ORDER BY last_seen_at_utc DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LastKnown
	for rows.Next() {
		snap, err := scanLastKnown(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, snap)
	}
	return out, rows.Err()
}

func (s *SQLiteStore) ListEvents(ctx context.Context, providerID string, limit int) ([]Event, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return nil, fmt.Errorf("providerevents: provider_id required")
	}
	if limit <= 0 || limit > DefaultEventsQueryCap {
		limit = DefaultEventsQueryCap
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT id, provider_id, session_id, attempt_id, occurred_at_utc, kind, outcome,
	failure_reason, auth_stage, message_family, binary_version,
	close_code, close_reason, diagnostic
FROM provider_connection_events
WHERE provider_id = ?
ORDER BY occurred_at_utc DESC, id DESC
LIMIT ?`, providerID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Event
	for rows.Next() {
		ev, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

func (s *SQLiteStore) Prune(ctx context.Context, olderThan time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, `
DELETE FROM provider_connection_events WHERE occurred_at_utc < ?`,
		olderThan.UTC().Format(time.RFC3339Nano))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func sanitizeEvent(event Event, now time.Time) Event {
	if event.OccurredAt.IsZero() {
		event.OccurredAt = now
	}
	event.ProviderID = strings.TrimSpace(event.ProviderID)
	event.SessionID = strings.TrimSpace(event.SessionID)
	event.AttemptID = strings.TrimSpace(event.AttemptID)
	event.Kind = strings.TrimSpace(event.Kind)
	event.Outcome = strings.TrimSpace(event.Outcome)
	if event.Outcome == "" {
		event.Outcome = OutcomeFailure
	}
	if event.FailureReason != "" {
		event.FailureReason = NormalizeFailureReason(event.FailureReason)
	}
	event.AuthStage = RedactDiagnostic(event.AuthStage, 64)
	event.MessageFamily = RedactDiagnostic(event.MessageFamily, 64)
	event.BinaryVersion = RedactDiagnostic(event.BinaryVersion, 64)
	event.CloseReason = RedactDiagnostic(event.CloseReason, DefaultMaxDiagnostic)
	event.Diagnostic = RedactDiagnostic(event.Diagnostic, DefaultMaxDiagnostic)
	return event
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanEvent(row rowScanner) (Event, error) {
	var (
		ev          Event
		occurredRaw string
	)
	if err := row.Scan(
		&ev.ID,
		&ev.ProviderID,
		&ev.SessionID,
		&ev.AttemptID,
		&occurredRaw,
		&ev.Kind,
		&ev.Outcome,
		&ev.FailureReason,
		&ev.AuthStage,
		&ev.MessageFamily,
		&ev.BinaryVersion,
		&ev.CloseCode,
		&ev.CloseReason,
		&ev.Diagnostic,
	); err != nil {
		return Event{}, err
	}
	occurred, err := time.Parse(time.RFC3339Nano, occurredRaw)
	if err != nil {
		return Event{}, fmt.Errorf("parse occurred_at: %w", err)
	}
	ev.OccurredAt = occurred.UTC()
	return ev, nil
}

func scanLastKnown(row rowScanner) (LastKnown, error) {
	var (
		snap                                    LastKnown
		connectedRaw, heartbeatRaw, activityRaw string
		lastSeenRaw                             string
		routing                                 int
	)
	if err := row.Scan(
		&snap.ProviderID,
		&snap.AssignedID,
		&snap.BinaryVersion,
		&snap.ModelID,
		&snap.State,
		&snap.AuthState,
		&connectedRaw,
		&heartbeatRaw,
		&activityRaw,
		&lastSeenRaw,
		&routing,
	); err != nil {
		return LastKnown{}, err
	}
	connected, err := parseOptionalTime(connectedRaw)
	if err != nil {
		return LastKnown{}, err
	}
	heartbeat, err := parseOptionalTime(heartbeatRaw)
	if err != nil {
		return LastKnown{}, err
	}
	activity, err := parseOptionalTime(activityRaw)
	if err != nil {
		return LastKnown{}, err
	}
	lastSeen, err := time.Parse(time.RFC3339Nano, lastSeenRaw)
	if err != nil {
		return LastKnown{}, fmt.Errorf("parse last_seen_at: %w", err)
	}
	snap.ConnectedAt = connected
	snap.LastHeartbeatAt = heartbeat
	snap.LastActivityAt = activity
	snap.LastSeenAt = lastSeen.UTC()
	snap.RoutingEligible = routing != 0
	return snap, nil
}

func formatOptionalTime(t *time.Time) string {
	if t == nil || t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}

func parseOptionalTime(raw string) (*time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return nil, err
	}
	utc := t.UTC()
	return &utc, nil
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
