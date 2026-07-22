package providerevents

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

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
	ListLastKnown(ctx context.Context, limit int, afterProviderID string) ([]LastKnown, error)
	ListEvents(ctx context.Context, providerID string, limit int) ([]Event, error)
	LatestEventProvider(ctx context.Context, providerID string) (Event, bool, error)
	Prune(ctx context.Context, olderThan time.Time) (int64, error)
	ReconcileBounds(ctx context.Context) error
	Close() error
}

// SQLiteStore persists events in a dedicated coordinator SQLite file so
// journal maintenance never shares the money-path request-log writer lock.
type SQLiteStore struct {
	db             *sql.DB
	retention      time.Duration
	perProviderCap int
	anonymousCap   int
	globalCap      int
	now            func() time.Time
}

// DefaultDBPath returns the sibling DB path next to the primary coordinator DB.
func DefaultDBPath(storageDBPath string) string {
	dir := filepath.Dir(strings.TrimSpace(storageDBPath))
	if dir == "" || dir == "." {
		return "provider_connection_events.db"
	}
	return filepath.Join(dir, "provider_connection_events.db")
}

// Open opens (or creates) the dedicated provider-events SQLite database.
func Open(path string) (*SQLiteStore, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("providerevents: db path is required")
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.Exec(`PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;`); err != nil {
		_ = db.Close()
		return nil, err
	}
	return NewSQLiteStore(db)
}

// NewSQLiteStore migrates schema and returns a ready store.
func NewSQLiteStore(db *sql.DB) (*SQLiteStore, error) {
	if db == nil {
		return nil, fmt.Errorf("providerevents: db is required")
	}
	s := &SQLiteStore{
		db:             db,
		retention:      DefaultRetention,
		perProviderCap: DefaultPerProviderCap,
		anonymousCap:   DefaultAnonymousCap,
		globalCap:      DefaultGlobalCap,
		now:            func() time.Time { return time.Now().UTC() },
	}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *SQLiteStore) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
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
	ON provider_connection_events(provider_id, occurred_at_utc DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_provider_connection_events_time
	ON provider_connection_events(occurred_at_utc, id);

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
CREATE INDEX IF NOT EXISTS idx_provider_last_known_seen
	ON provider_last_known(last_seen_at_utc DESC, provider_id ASC);
`)
	return err
}

func (s *SQLiteStore) Record(ctx context.Context, event Event) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("providerevents: store closed")
	}
	event, err := sanitizeEvent(event, s.now())
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO provider_connection_events (
	provider_id, session_id, attempt_id, occurred_at_utc, kind, outcome,
	failure_reason, auth_stage, message_family, binary_version,
	close_code, close_reason, diagnostic
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ProviderID,
		event.SessionID,
		event.AttemptID,
		FormatFixedUTC(event.OccurredAt),
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
	if err := s.enforceProviderCap(ctx, event.ProviderID); err != nil {
		return err
	}
	return s.enforceGlobalCap(ctx)
}

func (s *SQLiteStore) enforceProviderCap(ctx context.Context, providerID string) error {
	capN := s.perProviderCap
	if providerID == AnonymousProviderID {
		capN = s.anonymousCap
	}
	if capN <= 0 {
		return nil
	}
	// Atomic excess deletion: keep newest capN rows for this provider.
	_, err := s.db.ExecContext(ctx, `
DELETE FROM provider_connection_events
WHERE provider_id = ?
  AND id NOT IN (
	SELECT id FROM provider_connection_events
	WHERE provider_id = ?
	ORDER BY occurred_at_utc DESC, id DESC
	LIMIT ?
)`, providerID, providerID, capN)
	return err
}

func (s *SQLiteStore) enforceGlobalCap(ctx context.Context) error {
	if s.globalCap <= 0 {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `
DELETE FROM provider_connection_events
WHERE id NOT IN (
	SELECT id FROM provider_connection_events
	ORDER BY occurred_at_utc DESC, id DESC
	LIMIT ?
)`, s.globalCap)
	return err
}

func (s *SQLiteStore) UpsertLastKnown(ctx context.Context, snap LastKnown) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("providerevents: store closed")
	}
	providerID := strings.TrimSpace(snap.ProviderID)
	if providerID == "" || providerID == AnonymousProviderID {
		return fmt.Errorf("providerevents: provider_id required")
	}
	if LooksLikeCredential(providerID) || LooksLikeCredential(snap.AssignedID) {
		return fmt.Errorf("providerevents: credential-shaped identifier rejected")
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
		FormatFixedUTC(snap.LastSeenAt),
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

func (s *SQLiteStore) ListLastKnown(ctx context.Context, limit int, afterProviderID string) ([]LastKnown, error) {
	if limit <= 0 || limit > DefaultListPageCap {
		limit = DefaultListPageCap
	}
	afterProviderID = strings.TrimSpace(afterProviderID)
	var (
		rows *sql.Rows
		err  error
	)
	if afterProviderID == "" {
		rows, err = s.db.QueryContext(ctx, `
SELECT provider_id, assigned_id, binary_version, model_id, state, auth_state,
	connected_at_utc, last_heartbeat_at_utc, last_activity_at_utc,
	last_seen_at_utc, routing_eligible
FROM provider_last_known
ORDER BY last_seen_at_utc DESC, provider_id ASC
LIMIT ?`, limit)
	} else {
		rows, err = s.db.QueryContext(ctx, `
SELECT provider_id, assigned_id, binary_version, model_id, state, auth_state,
	connected_at_utc, last_heartbeat_at_utc, last_activity_at_utc,
	last_seen_at_utc, routing_eligible
FROM provider_last_known
WHERE (last_seen_at_utc, provider_id) < (
	SELECT last_seen_at_utc, provider_id FROM provider_last_known WHERE provider_id = ?
)
ORDER BY last_seen_at_utc DESC, provider_id ASC
LIMIT ?`, afterProviderID, limit)
	}
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

func (s *SQLiteStore) LatestEventProvider(ctx context.Context, providerID string) (Event, bool, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" || providerID == AnonymousProviderID {
		return Event{}, false, nil
	}
	row := s.db.QueryRowContext(ctx, `
SELECT id, provider_id, session_id, attempt_id, occurred_at_utc, kind, outcome,
	failure_reason, auth_stage, message_family, binary_version,
	close_code, close_reason, diagnostic
FROM provider_connection_events
WHERE provider_id = ?
ORDER BY occurred_at_utc DESC, id DESC
LIMIT 1`, providerID)
	ev, err := scanEvent(row)
	if err == sql.ErrNoRows {
		return Event{}, false, nil
	}
	if err != nil {
		return Event{}, false, err
	}
	return ev, true, nil
}

func (s *SQLiteStore) Prune(ctx context.Context, olderThan time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, `
DELETE FROM provider_connection_events WHERE occurred_at_utc < ?`,
		FormatFixedUTC(olderThan.UTC()))
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if _, err := s.db.ExecContext(ctx, `
DELETE FROM provider_last_known WHERE last_seen_at_utc < ?`,
		FormatFixedUTC(olderThan.UTC())); err != nil {
		return n, err
	}
	return n, nil
}

func (s *SQLiteStore) ReconcileBounds(ctx context.Context) error {
	if s == nil || s.db == nil {
		return fmt.Errorf("providerevents: store closed")
	}
	cutoff := s.now().Add(-s.retention)
	if _, err := s.Prune(ctx, cutoff); err != nil {
		return err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT provider_id FROM provider_connection_events`)
	if err != nil {
		return err
	}
	var providers []string
	for rows.Next() {
		var providerID string
		if err := rows.Scan(&providerID); err != nil {
			rows.Close()
			return err
		}
		providers = append(providers, providerID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, providerID := range providers {
		if err := s.enforceProviderCap(ctx, providerID); err != nil {
			return err
		}
	}
	return s.enforceGlobalCap(ctx)
}

func sanitizeEvent(event Event, now time.Time) (Event, error) {
	if event.OccurredAt.IsZero() {
		event.OccurredAt = now
	}
	event.ProviderID = strings.TrimSpace(event.ProviderID)
	if event.ProviderID == "" {
		event.ProviderID = AnonymousProviderID
	}
	event.SessionID = strings.TrimSpace(event.SessionID)
	event.AttemptID = strings.TrimSpace(event.AttemptID)
	if LooksLikeCredential(event.ProviderID) || LooksLikeCredential(event.SessionID) || LooksLikeCredential(event.AttemptID) {
		return Event{}, fmt.Errorf("providerevents: credential-shaped identifier rejected")
	}
	event.Kind = strings.TrimSpace(event.Kind)
	event.Outcome = strings.TrimSpace(event.Outcome)
	if event.Outcome == "" {
		event.Outcome = OutcomeFailure
	}
	if !KnownKind(event.Kind) {
		return Event{}, fmt.Errorf("providerevents: unknown kind %q", event.Kind)
	}
	if !KnownOutcome(event.Outcome) {
		return Event{}, fmt.Errorf("providerevents: unknown outcome %q", event.Outcome)
	}
	if event.Outcome == OutcomeFailure {
		if event.FailureReason == "" {
			event.FailureReason = ReasonOther
		} else {
			event.FailureReason = NormalizeFailureReason(event.FailureReason)
		}
	} else {
		event.FailureReason = ""
	}
	event.AuthStage = RedactDiagnostic(event.AuthStage, 64)
	event.MessageFamily = RedactDiagnostic(event.MessageFamily, 64)
	event.BinaryVersion = RedactDiagnostic(event.BinaryVersion, 64)
	// Close reason is closed-taxonomy only — never persist free-text wire reasons.
	if event.CloseReason != "" {
		event.CloseReason = NormalizeFailureReason(event.CloseReason)
	}
	event.Diagnostic = RedactDiagnostic(event.Diagnostic, DefaultMaxDiagnostic)
	return event, nil
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
	occurred, err := time.Parse(FixedUTCLayout, occurredRaw)
	if err != nil {
		// Accept legacy RFC3339Nano rows written before fixed-width migration.
		occurred, err = time.Parse(time.RFC3339Nano, occurredRaw)
		if err != nil {
			return Event{}, fmt.Errorf("parse occurred_at: %w", err)
		}
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
	lastSeen, err := time.Parse(FixedUTCLayout, lastSeenRaw)
	if err != nil {
		lastSeen, err = time.Parse(time.RFC3339Nano, lastSeenRaw)
		if err != nil {
			return LastKnown{}, fmt.Errorf("parse last_seen_at: %w", err)
		}
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
	return FormatFixedUTC(*t)
}

func parseOptionalTime(raw string) (*time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	t, err := time.Parse(FixedUTCLayout, raw)
	if err != nil {
		t, err = time.Parse(time.RFC3339Nano, raw)
		if err != nil {
			return nil, err
		}
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
