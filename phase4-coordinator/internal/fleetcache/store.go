package fleetcache

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
)

const maxScopes = 100000

var (
	ErrUnavailable = errors.New("fleet cache authority unavailable")
	ErrPending     = errors.New("fleet cache purge acknowledgement pending")
)

type Store struct {
	db  *sql.DB
	now func() time.Time
}

type Grant struct {
	ConversationKey string `json:"conversation_key"`
	Generation      int64  `json:"generation"`
}

type Purge struct {
	PurgeID         string `json:"purge_id"`
	ProviderID      string `json:"provider_id"`
	ConversationKey string `json:"conversation_key"`
	Generation      int64  `json:"generation"`
}

type PurgeResult struct {
	Pending []Purge
}

func NewStore(db *sql.DB) (*Store, error) {
	if db == nil {
		return nil, fmt.Errorf("%w: nil database", ErrUnavailable)
	}
	s := &Store{db: db, now: func() time.Time { return time.Now().UTC() }}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	const schema = `
CREATE TABLE IF NOT EXISTS fleet_cache_scopes (
  account_id TEXT NOT NULL,
  conversation_key TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK(generation >= 1),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(account_id, conversation_key, provider_id)
);
CREATE INDEX IF NOT EXISTS idx_fleet_cache_scopes_account_provider
  ON fleet_cache_scopes(account_id, provider_id);
CREATE TABLE IF NOT EXISTS fleet_cache_purges (
  purge_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  conversation_key TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK(generation >= 1),
  created_at TEXT NOT NULL,
  UNIQUE(account_id, conversation_key, provider_id)
);
CREATE INDEX IF NOT EXISTS idx_fleet_cache_purges_provider
  ON fleet_cache_purges(provider_id, created_at);
CREATE INDEX IF NOT EXISTS idx_fleet_cache_purges_account
  ON fleet_cache_purges(account_id, provider_id);
`
	if _, err := s.db.ExecContext(ctx, schema); err != nil {
		return fmt.Errorf("%w: migrate: %v", ErrUnavailable, err)
	}
	return nil
}

// Grant durably registers the authenticated account/conversation/provider scope
// before returning eligibility. Outstanding account/provider revocation work
// fences all keys for that pair until the provider acknowledges it.
func (s *Store) Grant(ctx context.Context, accountID, conversationKey, providerID string) (Grant, error) {
	accountID = strings.TrimSpace(accountID)
	conversationKey = strings.TrimSpace(conversationKey)
	providerID = strings.TrimSpace(providerID)
	if accountID == "" || conversationKey == "" || providerID == "" {
		return Grant{}, fmt.Errorf("%w: empty grant scope", ErrUnavailable)
	}
	conversationKey = providerConversationKey(accountID, conversationKey)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Grant{}, fmt.Errorf("%w: begin grant: %v", ErrUnavailable, err)
	}
	defer tx.Rollback()
	var pending int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM fleet_cache_purges WHERE account_id = ? AND provider_id = ?`, accountID, providerID).Scan(&pending); err != nil {
		return Grant{}, fmt.Errorf("%w: inspect pending: %v", ErrUnavailable, err)
	}
	if pending != 0 {
		return Grant{}, ErrPending
	}
	var generation int64
	err = tx.QueryRowContext(ctx, `SELECT generation FROM fleet_cache_scopes WHERE account_id = ? AND conversation_key = ? AND provider_id = ?`, accountID, conversationKey, providerID).Scan(&generation)
	if errors.Is(err, sql.ErrNoRows) {
		var count int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM fleet_cache_scopes`).Scan(&count); err != nil {
			return Grant{}, fmt.Errorf("%w: count scopes: %v", ErrUnavailable, err)
		}
		if count >= maxScopes {
			return Grant{}, fmt.Errorf("%w: scope bound reached", ErrUnavailable)
		}
		generation = 1
		now := s.now().Format(time.RFC3339Nano)
		if _, err := tx.ExecContext(ctx, `INSERT INTO fleet_cache_scopes(account_id, conversation_key, provider_id, generation, created_at, updated_at) VALUES(?,?,?,?,?,?)`, accountID, conversationKey, providerID, generation, now, now); err != nil {
			return Grant{}, fmt.Errorf("%w: register scope: %v", ErrUnavailable, err)
		}
	} else if err != nil {
		return Grant{}, fmt.Errorf("%w: load generation: %v", ErrUnavailable, err)
	}
	if err := tx.Commit(); err != nil {
		return Grant{}, fmt.Errorf("%w: commit grant: %v", ErrUnavailable, err)
	}
	return Grant{ConversationKey: conversationKey, Generation: generation}, nil
}

func providerConversationKey(accountID, gatewayKey string) string {
	h := sha256.New()
	_, _ = h.Write([]byte("spec037-v0.2-fleet-cache-grant-v1\n"))
	var size [8]byte
	binary.BigEndian.PutUint64(size[:], uint64(len(accountID)))
	_, _ = h.Write(size[:])
	_, _ = h.Write([]byte(accountID))
	binary.BigEndian.PutUint64(size[:], uint64(len(gatewayKey)))
	_, _ = h.Write(size[:])
	_, _ = h.Write([]byte(gatewayKey))
	return "conv:" + hex.EncodeToString(h.Sum(nil))
}

// PurgeAccount advances every registered scope before returning and records a
// durable delivery obligation for each provider/key. Repeated calls while ACKs
// are pending are idempotent and return the existing obligations.
func (s *Store) PurgeAccount(ctx context.Context, accountID string) (PurgeResult, error) {
	accountID = strings.TrimSpace(accountID)
	if accountID == "" {
		return PurgeResult{}, fmt.Errorf("%w: empty account", ErrUnavailable)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PurgeResult{}, fmt.Errorf("%w: begin purge: %v", ErrUnavailable, err)
	}
	defer tx.Rollback()
	existing, err := pendingForAccount(ctx, tx, accountID)
	if err != nil {
		return PurgeResult{}, err
	}
	if len(existing) != 0 {
		if err := tx.Commit(); err != nil {
			return PurgeResult{}, fmt.Errorf("%w: commit existing purge: %v", ErrUnavailable, err)
		}
		return PurgeResult{Pending: existing}, nil
	}
	rows, err := tx.QueryContext(ctx, `SELECT conversation_key, provider_id, generation FROM fleet_cache_scopes WHERE account_id = ? ORDER BY provider_id, conversation_key`, accountID)
	if err != nil {
		return PurgeResult{}, fmt.Errorf("%w: list scopes: %v", ErrUnavailable, err)
	}
	type scope struct {
		key, provider string
		generation    int64
	}
	var scopes []scope
	for rows.Next() {
		var v scope
		if err := rows.Scan(&v.key, &v.provider, &v.generation); err != nil {
			rows.Close()
			return PurgeResult{}, fmt.Errorf("%w: scan scope: %v", ErrUnavailable, err)
		}
		scopes = append(scopes, v)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return PurgeResult{}, fmt.Errorf("%w: iterate scopes: %v", ErrUnavailable, err)
	}
	if err := rows.Close(); err != nil {
		return PurgeResult{}, fmt.Errorf("%w: close scopes: %v", ErrUnavailable, err)
	}
	now := s.now().Format(time.RFC3339Nano)
	pending := make([]Purge, 0, len(scopes))
	for _, scope := range scopes {
		purgeID, err := newPurgeID()
		if err != nil {
			return PurgeResult{}, fmt.Errorf("%w: purge id: %v", ErrUnavailable, err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO fleet_cache_purges(purge_id, account_id, conversation_key, provider_id, generation, created_at) VALUES(?,?,?,?,?,?)`, purgeID, accountID, scope.key, scope.provider, scope.generation, now); err != nil {
			return PurgeResult{}, fmt.Errorf("%w: record purge: %v", ErrUnavailable, err)
		}
		result, err := tx.ExecContext(ctx, `UPDATE fleet_cache_scopes SET generation = ?, updated_at = ? WHERE account_id = ? AND conversation_key = ? AND provider_id = ? AND generation = ?`, scope.generation+1, now, accountID, scope.key, scope.provider, scope.generation)
		if err != nil {
			return PurgeResult{}, fmt.Errorf("%w: advance generation: %v", ErrUnavailable, err)
		}
		if changed, err := result.RowsAffected(); err != nil || changed != 1 {
			return PurgeResult{}, fmt.Errorf("%w: advance generation changed %d rows: %v", ErrUnavailable, changed, err)
		}
		pending = append(pending, Purge{PurgeID: purgeID, ProviderID: scope.provider, ConversationKey: scope.key, Generation: scope.generation})
	}
	if err := tx.Commit(); err != nil {
		return PurgeResult{}, fmt.Errorf("%w: commit purge: %v", ErrUnavailable, err)
	}
	return PurgeResult{Pending: pending}, nil
}

func (s *Store) PendingForProvider(ctx context.Context, providerID string) ([]Purge, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT purge_id, provider_id, conversation_key, generation FROM fleet_cache_purges WHERE provider_id = ? ORDER BY conversation_key, purge_id`, strings.TrimSpace(providerID))
	if err != nil {
		return nil, fmt.Errorf("%w: list provider purges: %v", ErrUnavailable, err)
	}
	defer rows.Close()
	return scanPurges(rows)
}

func (s *Store) PendingForAccount(ctx context.Context, accountID string) ([]Purge, error) {
	return pendingForAccount(ctx, s.db, strings.TrimSpace(accountID))
}

func (s *Store) Ack(ctx context.Context, providerID string, purge Purge, purged bool) (bool, error) {
	if !purged {
		return false, nil
	}
	res, err := s.db.ExecContext(ctx, `DELETE FROM fleet_cache_purges WHERE purge_id = ? AND provider_id = ? AND conversation_key = ? AND generation = ?`, purge.PurgeID, strings.TrimSpace(providerID), purge.ConversationKey, purge.Generation)
	if err != nil {
		return false, fmt.Errorf("%w: acknowledge purge: %v", ErrUnavailable, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%w: acknowledge result: %v", ErrUnavailable, err)
	}
	return n == 1, nil
}

type queryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func pendingForAccount(ctx context.Context, q queryer, accountID string) ([]Purge, error) {
	rows, err := q.QueryContext(ctx, `SELECT purge_id, provider_id, conversation_key, generation FROM fleet_cache_purges WHERE account_id = ? ORDER BY provider_id, conversation_key, purge_id`, accountID)
	if err != nil {
		return nil, fmt.Errorf("%w: list account purges: %v", ErrUnavailable, err)
	}
	defer rows.Close()
	return scanPurges(rows)
}

func scanPurges(rows *sql.Rows) ([]Purge, error) {
	var out []Purge
	for rows.Next() {
		var p Purge
		if err := rows.Scan(&p.PurgeID, &p.ProviderID, &p.ConversationKey, &p.Generation); err != nil {
			return nil, fmt.Errorf("%w: scan purge: %v", ErrUnavailable, err)
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: iterate purges: %v", ErrUnavailable, err)
	}
	return out, nil
}

func newPurgeID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return "fcp_" + hex.EncodeToString(raw[:]), nil
}
