package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

var (
	_ storage.AuthStore     = (*Store)(nil)
	_ storage.AccountStore  = (*Store)(nil)
	_ storage.KeyStore      = (*Store)(nil)
	_ storage.UsageStore    = (*Store)(nil)
	_ storage.FeedbackStore = (*Store)(nil)
	_ storage.AuditStore    = (*Store)(nil)
	_ storage.CapacityStore = (*Store)(nil)
)

func Open(ctx context.Context, path string) (*Store, error) {
	if path == "" {
		return nil, fmt.Errorf("sqlite db path must be set")
	}
	db, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.ExecContext(ctx, "PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;"); err != nil {
		_ = db.Close()
		return nil, err
	}
	store := &Store{db: db}
	if err := store.Migrate(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

func (s *Store) Migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, schemaSQL); err != nil {
		return err
	}
	if err := s.ensureOAuthStateActionColumn(ctx); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, ?)", encodeTime(time.Now().UTC()))
	return err
}

// ensureOAuthStateActionColumn handles upgrade-in-place for pre-existing
// gateway.db files that were created before `oauth_states.action` was added
// to schemaSQL. Mirrors phase4-coordinator/internal/auth/tokens.go's
// ensureProviderIDColumn — check PRAGMA table_info, ALTER TABLE if missing.
func (s *Store) ensureOAuthStateActionColumn(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(oauth_states)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasAction := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == "action" {
			hasAction = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if hasAction {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE oauth_states ADD COLUMN action TEXT NOT NULL DEFAULT ''`)
	return err
}

func (s *Store) CreateAccount(ctx context.Context, account storage.Account) error {
	if account.CreatedAt.IsZero() {
		account.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO accounts(account_id, status, quota_class, concurrency_class, created_at)
		VALUES(?, ?, ?, ?, ?)`,
		account.AccountID, nonEmpty(account.Status, "active"), nonEmpty(account.QuotaClass, "default"),
		nonEmpty(account.ConcurrencyClass, "default"), encodeTime(account.CreatedAt))
	return err
}

func (s *Store) AddAccountIdentity(ctx context.Context, identity storage.AccountIdentity) error {
	if identity.CreatedAt.IsZero() {
		identity.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO account_identities(account_id, provider, provider_user_id, email, created_at)
		VALUES(?, ?, ?, ?, ?)`,
		identity.AccountID, identity.Provider, identity.ProviderUserID, identity.Email, encodeTime(identity.CreatedAt))
	return err
}

func (s *Store) LookupAccountByIdentity(ctx context.Context, provider, providerUserID string) (storage.Account, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT a.account_id, a.status, a.quota_class, a.concurrency_class, a.created_at
		FROM account_identities i
		JOIN accounts a ON a.account_id = i.account_id
		WHERE i.provider = ? AND i.provider_user_id = ?`, provider, providerUserID)
	var account storage.Account
	var created string
	if err := row.Scan(&account.AccountID, &account.Status, &account.QuotaClass, &account.ConcurrencyClass, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.Account{}, storage.ErrNotFound
		}
		return storage.Account{}, err
	}
	account.CreatedAt = decodeTime(created)
	return account, nil
}

func (s *Store) LookupAccount(ctx context.Context, accountID string) (storage.Account, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT account_id, status, quota_class, concurrency_class, created_at
		FROM accounts
		WHERE account_id = ?`, accountID)
	var account storage.Account
	var created string
	if err := row.Scan(&account.AccountID, &account.Status, &account.QuotaClass, &account.ConcurrencyClass, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.Account{}, storage.ErrNotFound
		}
		return storage.Account{}, err
	}
	account.CreatedAt = decodeTime(created)
	return account, nil
}

func (s *Store) CreateAPIKey(ctx context.Context, key storage.APIKey) error {
	if key.CreatedAt.IsZero() {
		key.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		key.KeyID, key.AccountID, key.KeyHash, key.KeyHashPrefix, nonEmpty(key.Status, "active"), encodeTime(key.CreatedAt))
	return err
}

func (s *Store) ValidateAPIKeyHash(ctx context.Context, keyHash []byte) (storage.KeyValidation, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT k.key_id, k.account_id, k.status, k.key_hash_prefix, k.created_at,
		       a.status, a.quota_class, a.concurrency_class
		FROM api_keys k
		JOIN accounts a ON a.account_id = k.account_id
		WHERE k.key_hash = ?
		LIMIT 1`, keyHash)
	var validation storage.KeyValidation
	var created string
	if err := row.Scan(&validation.KeyID, &validation.AccountID, &validation.KeyStatus, &validation.KeyHashPrefix, &created, &validation.AccountStatus, &validation.QuotaClass, &validation.ConcurrencyClass); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.KeyValidation{}, storage.ErrNotFound
		}
		return storage.KeyValidation{}, err
	}
	validation.CreatedAt = decodeTime(created)
	validation.Active = validation.KeyStatus == "active" && validation.AccountStatus == "active"
	return validation, nil
}

func (s *Store) ListAPIKeys(ctx context.Context, accountID string) ([]storage.APIKeySummary, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT key_id, key_hash_prefix, status, created_at, revoked_at
		FROM api_keys
		WHERE account_id = ?
		ORDER BY created_at ASC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var keys []storage.APIKeySummary
	for rows.Next() {
		var key storage.APIKeySummary
		var created string
		var revoked string
		if err := rows.Scan(&key.KeyID, &key.KeyHashPrefix, &key.Status, &created, &revoked); err != nil {
			return nil, err
		}
		key.CreatedAt = decodeTime(created)
		if revoked != "" {
			key.RevokedAt = decodeTime(revoked)
		}
		keys = append(keys, key)
	}
	return keys, rows.Err()
}

func (s *Store) RevokeAPIKey(ctx context.Context, keyID, actor, requestID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer rollback(tx)
	var accountID string
	if err := tx.QueryRowContext(ctx, `SELECT account_id FROM api_keys WHERE key_id = ?`, keyID).Scan(&accountID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrNotFound
		}
		return err
	}
	now := encodeTime(time.Now().UTC())
	if _, err := tx.ExecContext(ctx, `UPDATE api_keys SET status = 'revoked', revoked_at = ? WHERE key_id = ?`, now, keyID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'revoked', ?, ?)`, keyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RevokeAPIKeyForAccount(ctx context.Context, accountID, keyID, actor, requestID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer rollback(tx)
	now := encodeTime(time.Now().UTC())
	res, err := tx.ExecContext(ctx, `UPDATE api_keys SET status = 'revoked', revoked_at = ? WHERE key_id = ? AND account_id = ?`, now, keyID, accountID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return storage.ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'revoked', ?, ?)`, keyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RotateAPIKey(ctx context.Context, oldKeyID, accountID string, newKey storage.APIKey, actor, requestID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer rollback(tx)
	var existingAccountID string
	if err := tx.QueryRowContext(ctx, `SELECT account_id FROM api_keys WHERE key_id = ? AND account_id = ?`, oldKeyID, accountID).Scan(&existingAccountID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrNotFound
		}
		return err
	}
	if newKey.CreatedAt.IsZero() {
		newKey.CreatedAt = time.Now().UTC()
	}
	newKey.AccountID = accountID
	now := encodeTime(time.Now().UTC())
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		newKey.KeyID, accountID, newKey.KeyHash, newKey.KeyHashPrefix, nonEmpty(newKey.Status, "active"), encodeTime(newKey.CreatedAt)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE api_keys SET status = 'revoked', revoked_at = ? WHERE key_id = ? AND account_id = ?`, now, oldKeyID, accountID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'rotated_from', ?, ?)`, oldKeyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at)
		VALUES(?, ?, ?, 'rotated_to', ?, ?)`, newKey.KeyID, accountID, requestID, actor, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) StoreOAuthState(ctx context.Context, state storage.OAuthState) error {
	if state.CreatedAt.IsZero() {
		state.CreatedAt = time.Now().UTC()
	}
	if state.ExpiresAt.IsZero() {
		state.ExpiresAt = state.CreatedAt.Add(10 * time.Minute)
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO oauth_states(state_hash, session_id, redirect_uri, client_ip, created_at, expires_at, action)
		VALUES(?, ?, ?, ?, ?, ?, ?)`,
		state.StateHash, state.SessionID, state.RedirectURI, state.ClientIP,
		encodeTime(state.CreatedAt), encodeTime(state.ExpiresAt), state.Action)
	return err
}

func (s *Store) ConsumeOAuthState(ctx context.Context, stateHash []byte, sessionID string, now time.Time) (string, string, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	var redirectURI string
	var expiresAt string
	var consumedAt string
	var action string
	if err := tx.QueryRowContext(ctx, `
		SELECT redirect_uri, expires_at, consumed_at, action
		FROM oauth_states
		WHERE state_hash = ? AND session_id = ?`,
		stateHash, sessionID).Scan(&redirectURI, &expiresAt, &consumedAt, &action); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", "", storage.ErrNotFound
		}
		return "", "", err
	}
	if consumedAt != "" || !now.Before(decodeTime(expiresAt)) {
		return "", "", storage.ErrNotFound
	}
	_, err = tx.ExecContext(ctx, `UPDATE oauth_states SET consumed_at = ? WHERE state_hash = ?`, encodeTime(now.UTC()), stateHash)
	if err != nil {
		return "", "", err
	}
	return redirectURI, action, tx.Commit()
}

func (s *Store) RecordSignupEvent(ctx context.Context, event storage.SignupEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO signup_events(event_id, account_id, client_ip, provider, created_at)
		VALUES(?, ?, ?, ?, ?)`, event.EventID, event.AccountID, event.ClientIP, event.Provider, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) CountSignupEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM signup_events
		WHERE client_ip = ? AND created_at >= ?`, clientIP, encodeTime(since)).Scan(&count)
	return count, err
}

func (s *Store) RecordDemoSessionEvent(ctx context.Context, event storage.DemoSessionEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO demo_session_events(event_id, client_ip, created_at)
		VALUES(?, ?, ?)`, event.EventID, event.ClientIP, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) CountDemoSessionEventsSince(ctx context.Context, clientIP string, since time.Time) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM demo_session_events
		WHERE client_ip = ? AND created_at >= ?`, clientIP, encodeTime(since)).Scan(&count)
	return count, err
}

func (s *Store) ReserveQuota(ctx context.Context, req storage.ReservationRequest) (storage.QuotaDecision, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return storage.QuotaDecision{}, err
	}
	defer tx.Rollback()
	if req.CreatedAt.IsZero() {
		req.CreatedAt = time.Now().UTC()
	}
	if _, err := reapExpiredReservationsTx(ctx, tx, req.CreatedAt); err != nil {
		return storage.QuotaDecision{}, err
	}
	used, reserved, err := dailyUsageTx(ctx, tx, req.AccountID, req.WindowDate)
	if err != nil {
		return storage.QuotaDecision{}, err
	}
	remaining := req.DailyQuota - used - reserved
	decision := storage.QuotaDecision{
		Admitted: false, LimitTokens: req.DailyQuota, UsedTokens: used, ReservedTokens: reserved,
		RemainingTokens: max64(0, remaining), ResetUnix: resetUnix(req.WindowDate),
	}
	if req.RequestedTokens > remaining {
		tx.Rollback() // read-only path; rollback is equivalent to commit here
		return decision, storage.ErrQuotaExceeded
	}
	if req.ExpiresAt.IsZero() {
		req.ExpiresAt = req.CreatedAt.Add(24 * time.Hour)
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO quota_reservations(account_id, request_id, window_date, reserved_tokens, status, expires_at, created_at)
		VALUES(?, ?, ?, ?, 'active', ?, ?)`,
		req.AccountID, req.RequestID, req.WindowDate, req.RequestedTokens, encodeTime(req.ExpiresAt), encodeTime(req.CreatedAt))
	if err != nil {
		return storage.QuotaDecision{}, err
	}
	decision.Admitted = true
	decision.ReservedTokens += req.RequestedTokens
	decision.RemainingTokens = max64(0, remaining-req.RequestedTokens)
	return decision, tx.Commit()
}

func (s *Store) SettleReservation(ctx context.Context, settlement storage.ReservationSettlement) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var windowDate string
	var status string
	if err := tx.QueryRowContext(ctx, `
		SELECT window_date, status FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`, settlement.AccountID, settlement.RequestID).Scan(&windowDate, &status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	if status != "active" {
		return fmt.Errorf("reservation %s is %s", settlement.RequestID, status)
	}
	if settlement.SettledAt.IsZero() {
		settlement.SettledAt = time.Now().UTC()
	}
	if err := normalizeSettlementTokens(&settlement); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?
		WHERE account_id = ? AND request_id = ?`,
		settlement.TotalTokens, encodeTime(settlement.SettledAt), settlement.AccountID, settlement.RequestID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO usage_events(request_id, account_id, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		settlement.RequestID, settlement.AccountID, windowDate, settlement.PromptTokens, settlement.CompletionTokens,
		settlement.TotalTokens, settlement.TokenSource, settlement.Outcome, encodeTime(settlement.SettledAt))
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) SettleDemoReservation(ctx context.Context, settlement storage.ReservationSettlement, demo storage.DemoUsageEvent) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var windowDate string
	var status string
	if err := tx.QueryRowContext(ctx, `
		SELECT window_date, status FROM quota_reservations
		WHERE account_id = ? AND request_id = ?`, settlement.AccountID, settlement.RequestID).Scan(&windowDate, &status); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.ErrReservationNotFound
		}
		return err
	}
	if status != "active" {
		return fmt.Errorf("reservation %s is %s", settlement.RequestID, status)
	}
	if settlement.SettledAt.IsZero() {
		settlement.SettledAt = time.Now().UTC()
	}
	if err := normalizeSettlementTokens(&settlement); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'settled', settled_tokens = ?, settled_at = ?
		WHERE account_id = ? AND request_id = ?`,
		settlement.TotalTokens, encodeTime(settlement.SettledAt), settlement.AccountID, settlement.RequestID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO usage_events(request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		settlement.RequestID, settlement.AccountID, demo.ClientIP, windowDate, settlement.PromptTokens, settlement.CompletionTokens,
		settlement.TotalTokens, settlement.TokenSource, settlement.Outcome, encodeTime(settlement.SettledAt))
	if err != nil {
		return err
	}
	if demo.CreatedAt.IsZero() {
		demo.CreatedAt = settlement.SettledAt
	}
	if demo.WindowDate == "" {
		demo.WindowDate = windowDate
	}
	if demo.TotalTokens == 0 {
		demo.TotalTokens = settlement.TotalTokens
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO demo_usage_events(request_id, client_ip, demo_token_hash, window_date, total_tokens, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		demo.RequestID, demo.ClientIP, demo.DemoTokenHash, demo.WindowDate, demo.TotalTokens, encodeTime(demo.CreatedAt))
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RefundReservation(ctx context.Context, accountID, requestID string, refundedAt int64) error {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	when := time.Unix(refundedAt, 0).UTC()
	res, err := tx.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'refunded', settled_tokens = 0, settled_at = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		encodeTime(when), accountID, requestID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return storage.ErrReservationNotFound
	}
	return tx.Commit()
}

func (s *Store) AcquireConcurrency(ctx context.Context, req storage.ConcurrencyRequest) (storage.ConcurrencyDecision, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	defer tx.Rollback()
	if req.CreatedAt.IsZero() {
		req.CreatedAt = time.Now().UTC()
	}
	if req.ExpiresAt.IsZero() {
		req.ExpiresAt = req.CreatedAt.Add(10 * time.Minute)
	}
	_, err = tx.ExecContext(ctx, `
		UPDATE concurrency_reservations
		SET status = 'expired', released_at = ?
		WHERE account_id = ? AND status = 'active' AND expires_at <= ?`,
		encodeTime(req.CreatedAt), req.AccountID, encodeTime(req.CreatedAt))
	if err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	var active int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM concurrency_reservations
		WHERE account_id = ? AND status = 'active' AND expires_at > ?`,
		req.AccountID, encodeTime(req.CreatedAt)).Scan(&active); err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	decision := storage.ConcurrencyDecision{Admitted: false, Limit: req.Limit, Active: active}
	if active >= req.Limit {
		if err := tx.Commit(); err != nil {
			return storage.ConcurrencyDecision{}, err
		}
		return decision, storage.ErrQuotaExceeded
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO concurrency_reservations(account_id, request_id, status, expires_at, created_at)
		VALUES(?, ?, 'active', ?, ?)`,
		req.AccountID, req.RequestID, encodeTime(req.ExpiresAt), encodeTime(req.CreatedAt))
	if err != nil {
		return storage.ConcurrencyDecision{}, err
	}
	decision.Admitted = true
	decision.Active = active + 1
	return decision, tx.Commit()
}

func (s *Store) ReleaseConcurrency(ctx context.Context, accountID, requestID string, releasedAt time.Time) error {
	if releasedAt.IsZero() {
		releasedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE concurrency_reservations
		SET status = 'released', released_at = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`,
		encodeTime(releasedAt), accountID, requestID)
	return err
}

func (s *Store) InsertUsageEvent(ctx context.Context, event storage.UsageEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	if event.PromptTokens < 0 || event.CompletionTokens < 0 || event.TotalTokens < 0 {
		return fmt.Errorf("usage tokens must be non-negative")
	}
	if event.PromptTokens > math.MaxInt64-event.CompletionTokens {
		return fmt.Errorf("usage token total overflows int64")
	}
	sum := event.PromptTokens + event.CompletionTokens
	if event.TotalTokens == 0 {
		event.TotalTokens = sum
	} else if event.TotalTokens != sum {
		return fmt.Errorf("usage total_tokens does not match prompt_tokens plus completion_tokens")
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO usage_events(request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.RequestID, event.AccountID, event.DemoIdentity, event.WindowDate, event.PromptTokens, event.CompletionTokens,
		event.TotalTokens, event.TokenSource, event.Outcome, encodeTime(event.CreatedAt))
	return err
}

func normalizeSettlementTokens(settlement *storage.ReservationSettlement) error {
	if settlement.PromptTokens < 0 || settlement.CompletionTokens < 0 || settlement.TotalTokens < 0 {
		return fmt.Errorf("settlement tokens must be non-negative")
	}
	if settlement.PromptTokens > math.MaxInt64-settlement.CompletionTokens {
		return fmt.Errorf("settlement token total overflows int64")
	}
	sum := settlement.PromptTokens + settlement.CompletionTokens
	if settlement.TotalTokens == 0 {
		settlement.TotalTokens = sum
	} else if settlement.TotalTokens != sum {
		return fmt.Errorf("settlement total_tokens does not match prompt_tokens plus completion_tokens")
	}
	if settlement.MaxTotalTokens > 0 && settlement.TotalTokens > settlement.MaxTotalTokens {
		return fmt.Errorf("settlement total_tokens exceeds request maximum")
	}
	return nil
}

func (s *Store) DailyUsage(ctx context.Context, accountID, windowDate string) (int64, int64, error) {
	return dailyUsageTx(ctx, s.db, accountID, windowDate)
}

func (s *Store) ReapExpiredReservations(ctx context.Context, now time.Time) (int64, error) {
	tx, err := s.beginImmediate(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	n, err := reapExpiredReservationsTx(ctx, tx, now)
	if err != nil {
		return 0, err
	}
	return n, tx.Commit()
}

func (s *Store) InsertFeedbackEvent(ctx context.Context, event storage.FeedbackEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO feedback_events(event_id, request_id, account_id, scope, rating, comment, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?)`,
		event.EventID, event.RequestID, event.AccountID, event.Scope, event.Rating, event.Comment, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) ListFeedbackEventsSince(ctx context.Context, since time.Time) ([]storage.FeedbackSummaryEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT event_id, request_id, account_id, scope, rating, comment, created_at
		FROM feedback_events
		WHERE created_at >= ?
		ORDER BY created_at ASC`, encodeTime(since))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []storage.FeedbackSummaryEvent
	for rows.Next() {
		var event storage.FeedbackSummaryEvent
		var created string
		if err := rows.Scan(&event.EventID, &event.RequestID, &event.AccountID, &event.Scope, &event.Rating, &event.Comment, &created); err != nil {
			return nil, err
		}
		event.CreatedAt = decodeTime(created)
		events = append(events, event)
	}
	return events, rows.Err()
}

func (s *Store) InsertAuditEvent(ctx context.Context, event storage.AuditEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO audit_events(event_id, request_id, account_id, actor, event_type, payload_json, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?)`,
		event.EventID, event.RequestID, event.AccountID, event.Actor, event.Type, event.Payload, encodeTime(event.CreatedAt))
	return err
}

func (s *Store) LatestCapacitySignals(ctx context.Context) ([]storage.CapacitySignalEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT c.event_id, c.signal, c.value, c.threshold, c.firing, c.created_at
		FROM capacity_signal_events c
		JOIN (
			SELECT signal, MAX(created_at) AS created_at
			FROM capacity_signal_events
			GROUP BY signal
		) latest ON latest.signal = c.signal AND latest.created_at = c.created_at
		ORDER BY c.signal ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storage.CapacitySignalEvent
	for rows.Next() {
		var event storage.CapacitySignalEvent
		var firing int
		var created string
		if err := rows.Scan(&event.EventID, &event.Signal, &event.Value, &event.Threshold, &firing, &created); err != nil {
			return nil, err
		}
		event.Firing = firing == 1
		event.CreatedAt = decodeTime(created)
		out = append(out, event)
	}
	return out, rows.Err()
}

func (s *Store) GetCapacityTier(ctx context.Context) (storage.CapacityTier, error) {
	row := s.db.QueryRowContext(ctx, `SELECT value, updated_at FROM runtime_config WHERE key = 'capacity_tier'`)
	var value string
	var updated string
	if err := row.Scan(&value, &updated); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.CapacityTier{Tier: 0}, nil
		}
		return storage.CapacityTier{}, err
	}
	var tier storage.CapacityTier
	if _, err := fmt.Sscanf(value, `{"tier":%d,"signals":%q}`, &tier.Tier, &tier.Signals); err != nil {
		return storage.CapacityTier{}, err
	}
	tier.UpdatedAt = decodeTime(updated)
	return tier, nil
}

func (s *Store) SetCapacityTier(ctx context.Context, tier storage.CapacityTier) error {
	if tier.UpdatedAt.IsZero() {
		tier.UpdatedAt = time.Now().UTC()
	}
	value := fmt.Sprintf(`{"tier":%d,"signals":%q}`, tier.Tier, tier.Signals)
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO runtime_config(key, value, updated_at)
		VALUES('capacity_tier', ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		value, encodeTime(tier.UpdatedAt))
	return err
}

func (s *Store) GetKillSwitch(ctx context.Context) (storage.KillSwitchState, error) {
	row := s.db.QueryRowContext(ctx, `SELECT value, updated_at FROM runtime_config WHERE key = 'kill_switch'`)
	var value string
	var updated string
	if err := row.Scan(&value, &updated); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return storage.KillSwitchState{}, nil
		}
		return storage.KillSwitchState{}, err
	}
	var state storage.KillSwitchState
	if err := json.Unmarshal([]byte(value), &state); err != nil {
		return storage.KillSwitchState{}, err
	}
	state.UpdatedAt = decodeTime(updated)
	return state, nil
}

func (s *Store) SetKillSwitch(ctx context.Context, state storage.KillSwitchState) error {
	if state.UpdatedAt.IsZero() {
		state.UpdatedAt = time.Now().UTC()
	}
	value, err := json.Marshal(struct {
		DemoOnly     bool `json:"demo_only"`
		AllPublicAPI bool `json:"all_public_api"`
	}{DemoOnly: state.DemoOnly, AllPublicAPI: state.AllPublicAPI})
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO runtime_config(key, value, updated_at)
		VALUES('kill_switch', ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		string(value), encodeTime(state.UpdatedAt))
	return err
}

func (s *Store) InsertCapacitySignalEvent(ctx context.Context, event storage.CapacitySignalEvent) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	firing := 0
	if event.Firing {
		firing = 1
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO capacity_signal_events(event_id, signal, value, threshold, firing, created_at)
		VALUES(?, ?, ?, ?, ?, ?)`,
		event.EventID, event.Signal, event.Value, event.Threshold, firing, encodeTime(event.CreatedAt))
	return err
}

type queryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

type execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func reapExpiredReservationsTx(ctx context.Context, q execer, now time.Time) (int64, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	res, err := q.ExecContext(ctx, `
		UPDATE quota_reservations
		SET status = 'expired', settled_tokens = 0, settled_at = ?
		WHERE status = 'active' AND expires_at <= ?`,
		encodeTime(now), encodeTime(now))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func dailyUsageTx(ctx context.Context, q queryer, accountID, windowDate string) (int64, int64, error) {
	var used sql.NullInt64
	if err := q.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(total_tokens), 0)
		FROM usage_events
		WHERE account_id = ? AND window_date = ?`, accountID, windowDate).Scan(&used); err != nil {
		return 0, 0, err
	}
	var reserved sql.NullInt64
	if err := q.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(reserved_tokens), 0)
		FROM quota_reservations
		WHERE account_id = ? AND window_date = ? AND status = 'active'`, accountID, windowDate).Scan(&reserved); err != nil {
		return 0, 0, err
	}
	return used.Int64, reserved.Int64, nil
}

type immediateTx struct {
	ctx  context.Context
	conn *sql.Conn
	done bool
}

func (tx *immediateTx) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	return tx.conn.ExecContext(ctx, query, args...)
}

func (tx *immediateTx) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	return tx.conn.QueryRowContext(ctx, query, args...)
}

func (tx *immediateTx) Commit() error {
	if tx.done {
		return nil
	}
	tx.done = true
	_, err := tx.conn.ExecContext(tx.ctx, "COMMIT")
	closeErr := tx.conn.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func (tx *immediateTx) Rollback() {
	if tx.done {
		return
	}
	tx.done = true
	_, _ = tx.conn.ExecContext(tx.ctx, "ROLLBACK")
	_ = tx.conn.Close()
}

func (s *Store) beginImmediate(ctx context.Context) (*immediateTx, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return &immediateTx{ctx: ctx, conn: conn}, nil
}

func rollback(tx *sql.Tx) {
	_ = tx.Rollback()
}

func encodeTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

func decodeTime(s string) time.Time {
	t, _ := time.Parse(time.RFC3339Nano, s)
	return t
}

func nonEmpty(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func resetUnix(windowDate string) int64 {
	t, err := time.Parse("2006-01-02", windowDate)
	if err != nil {
		return 0
	}
	return t.Add(24 * time.Hour).Unix()
}
