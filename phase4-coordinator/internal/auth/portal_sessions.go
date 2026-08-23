package auth

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// Portal read sessions are operator-minted, read-only web credentials.
// They are not provider tokens, GitHub cookies, or pair_ot values.
const (
	PortalReadSessionPrefix           = "mps1_"
	PortalReadSessionTTL              = 12 * time.Hour
	PortalReadSessionMintLimitPerHour = 5
	PortalReadSessionDefaultBaseURL   = "https://portal.malibu.tech"
)

var (
	ErrPortalSessionUnknownProvider = errors.New("portal session: provider has no active token")
	ErrPortalSessionRateLimited     = errors.New("portal session: mint rate limited")
	ErrPortalSessionInvalid         = errors.New("portal session invalid")
)

// PortalReadSessionMint is the one-time operator view of a newly minted
// read session. The cleartext token appears only here and in PortalURL.
type PortalReadSessionMint struct {
	ProviderID string
	Token      string
	PortalURL  string
	ExpiresAt  time.Time
}

type PortalReadSession struct {
	ProviderID string
	ExpiresAt  time.Time
}

func IsPortalReadSession(token string) bool {
	return strings.HasPrefix(strings.TrimSpace(token), PortalReadSessionPrefix)
}

func (s *Store) ensurePortalReadSessionSchema(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS portal_read_sessions (
	token_hash TEXT PRIMARY KEY,
	provider_id TEXT NOT NULL,
	expires_at TEXT NOT NULL,
	created_at TEXT NOT NULL,
	revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_read_sessions_provider_created
	ON portal_read_sessions(provider_id, created_at);
`)
	return err
}

func NormalizePortalBaseURL(raw string) string {
	base := strings.TrimRight(strings.TrimSpace(raw), "/")
	if base == "" {
		return PortalReadSessionDefaultBaseURL
	}
	parsed, err := url.Parse(base)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return PortalReadSessionDefaultBaseURL
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return PortalReadSessionDefaultBaseURL
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return PortalReadSessionDefaultBaseURL
	}
	return strings.TrimRight(parsed.Scheme+"://"+parsed.Host, "/")
}

func (s *Store) MintPortalReadSession(ctx context.Context, providerID, portalBaseURL string, now time.Time) (PortalReadSessionMint, error) {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return PortalReadSessionMint{}, fmt.Errorf("provider id is required")
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	active, err := s.HasActiveTokenForProvider(ctx, providerID)
	if err != nil {
		return PortalReadSessionMint{}, err
	}
	if !active {
		return PortalReadSessionMint{}, ErrPortalSessionUnknownProvider
	}
	since := timeText(now.Add(-time.Hour))
	var minted int
	if err := s.db.QueryRowContext(ctx, `
SELECT COUNT(1) FROM portal_read_sessions
 WHERE provider_id = ? AND created_at >= ?`, providerID, since).Scan(&minted); err != nil {
		return PortalReadSessionMint{}, err
	}
	if minted >= PortalReadSessionMintLimitPerHour {
		return PortalReadSessionMint{}, ErrPortalSessionRateLimited
	}
	secret, err := randomHex(32)
	if err != nil {
		return PortalReadSessionMint{}, err
	}
	token := PortalReadSessionPrefix + secret
	expires := now.Add(PortalReadSessionTTL)
	if _, err := s.db.ExecContext(ctx, `
INSERT INTO portal_read_sessions (token_hash, provider_id, expires_at, created_at)
VALUES (?, ?, ?, ?)`, tokenHash(token), providerID, timeText(expires), timeText(now)); err != nil {
		return PortalReadSessionMint{}, err
	}
	base := NormalizePortalBaseURL(portalBaseURL)
	return PortalReadSessionMint{
		ProviderID: providerID,
		Token:      token,
		PortalURL:  base + "/?ps=" + url.QueryEscape(token),
		ExpiresAt:  expires,
	}, nil
}

func (s *Store) ValidatePortalReadSession(ctx context.Context, raw string, now time.Time) (string, bool, error) {
	session, ok, err := s.LookupPortalReadSession(ctx, raw, now)
	if err != nil || !ok {
		return "", ok, err
	}
	return session.ProviderID, true, nil
}

func (s *Store) LookupPortalReadSession(ctx context.Context, raw string, now time.Time) (PortalReadSession, bool, error) {
	raw = strings.TrimSpace(raw)
	if !IsPortalReadSession(raw) {
		return PortalReadSession{}, false, nil
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	var providerID, expiresAt string
	err := s.db.QueryRowContext(ctx, `
SELECT provider_id, expires_at
  FROM portal_read_sessions
 WHERE token_hash = ? AND revoked_at IS NULL`, tokenHash(raw)).Scan(&providerID, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return PortalReadSession{}, false, nil
	}
	if err != nil {
		return PortalReadSession{}, false, err
	}
	expires, parseErr := time.Parse(time.RFC3339, expiresAt)
	if parseErr != nil || !expires.After(now) {
		return PortalReadSession{}, false, nil
	}
	return PortalReadSession{ProviderID: providerID, ExpiresAt: expires.UTC()}, true, nil
}

type portalReadValidator interface {
	ValidatePortalReadSession(ctx context.Context, raw string, now time.Time) (string, bool, error)
}

type providerTokenMarker interface {
	ValidateAndMarkTokenUsed(ctx context.Context, raw string) (string, bool, error)
}

type providerTokenReadOnly interface {
	ValidateTokenReadOnly(ctx context.Context, raw string) (string, bool, error)
}

// ValidateProviderAPIRead accepts either an FR-P12 provider bearer or an
// operator-minted portal read session. Portal sessions never mark provider
// token last_used_at.
func ValidateProviderAPIRead(ctx context.Context, store any, raw string) (string, bool, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || store == nil {
		return "", false, nil
	}
	if IsPortalReadSession(raw) {
		v, ok := store.(portalReadValidator)
		if !ok {
			return "", false, nil
		}
		return v.ValidatePortalReadSession(ctx, raw, time.Now().UTC())
	}
	if ro, ok := store.(providerTokenReadOnly); ok {
		return ro.ValidateTokenReadOnly(ctx, raw)
	}
	if marker, ok := store.(providerTokenMarker); ok {
		return marker.ValidateAndMarkTokenUsed(ctx, raw)
	}
	return "", false, nil
}

// ValidateProviderAPIReadAndMark is the earnings path: portal sessions stay
// read-only; provider bearers still mark last_used_at.
func ValidateProviderAPIReadAndMark(ctx context.Context, store any, raw string) (string, bool, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || store == nil {
		return "", false, nil
	}
	if IsPortalReadSession(raw) {
		v, ok := store.(portalReadValidator)
		if !ok {
			return "", false, nil
		}
		return v.ValidatePortalReadSession(ctx, raw, time.Now().UTC())
	}
	if marker, ok := store.(providerTokenMarker); ok {
		return marker.ValidateAndMarkTokenUsed(ctx, raw)
	}
	return "", false, nil
}
