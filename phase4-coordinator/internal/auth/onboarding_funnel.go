package auth

import (
	"context"
	"database/sql"
	"strings"
	"time"
)

// Operator-facing onboarding funnel states. These join referral redemption,
// bootstrap identity, and (when the caller supplies it) live presence.
// Redeemed is never a success state.
const (
	OnboardingStatePending       = "pending"
	OnboardingStateConfirmed     = "confirmed"
	OnboardingStateLive          = "live"
	OnboardingStateFailedExpired = "failed_expired"
	OnboardingStateFailedRevoked = "failed_revoked"

	OnboardingPresenceConnected = "connected"
	OnboardingPresenceOffline   = "offline"
	OnboardingPresenceUnknown   = "unknown"
)

// OnboardingAttemptRecord is the durable auth-SQLite side of one invite or
// bootstrap onboarding attempt. It never includes invite codes, code digests,
// tokens, or receipt public keys.
type OnboardingAttemptRecord struct {
	ProviderID         string
	Campaign           string
	IssuerID           string
	RedeemedAt         sql.NullString
	BootstrapCreatedAt sql.NullString
	ExpiresAt          sql.NullString
	ConfirmedAt        sql.NullString
	OperatorRevokedAt  sql.NullString
}

// OnboardingPresence is the optional live/last-known overlay supplied by the
// connection-event journal and/or the in-process pool. Empty timestamps mean
// the caller did not observe that signal.
type OnboardingPresence struct {
	Connected         bool
	LastSeenAt        string
	LastHeartbeatAt   string
	LastEventKind     string
	LastEventOutcome  string
	LastEventAt       string
	LastFailureReason string
}

// OnboardingAttempt is the operator-safe joined funnel row.
type OnboardingAttempt struct {
	ProviderID         string `json:"provider_id"`
	State              string `json:"onboarding_state"`
	Campaign           string `json:"campaign,omitempty"`
	IssuerID           string `json:"issuer_id,omitempty"`
	RedeemedAt         string `json:"redeemed_at,omitempty"`
	BootstrapCreatedAt string `json:"bootstrap_created_at,omitempty"`
	ExpiresAt          string `json:"expires_at,omitempty"`
	ConfirmedAt        string `json:"confirmed_at,omitempty"`
	OperatorRevokedAt  string `json:"operator_revoked_at,omitempty"`
	Presence           string `json:"presence"`
	LastSeenAt         string `json:"last_seen_at,omitempty"`
	LastHeartbeatAt    string `json:"last_heartbeat_at,omitempty"`
	LastEventKind      string `json:"last_event_kind,omitempty"`
	LastEventOutcome   string `json:"last_event_outcome,omitempty"`
	LastEventAt        string `json:"last_event_at,omitempty"`
	LastFailureReason  string `json:"last_failure_reason,omitempty"`
}

// OnboardingFunnelSummary counts exclusive funnel states.
type OnboardingFunnelSummary struct {
	Pending       int `json:"pending"`
	Confirmed     int `json:"confirmed"`
	Live          int `json:"live"`
	FailedExpired int `json:"failed_expired"`
	FailedRevoked int `json:"failed_revoked"`
}

var validOnboardingStates = map[string]bool{
	OnboardingStatePending:       true,
	OnboardingStateConfirmed:     true,
	OnboardingStateLive:          true,
	OnboardingStateFailedExpired: true,
	OnboardingStateFailedRevoked: true,
}

// ValidOnboardingState reports whether state is one of the exclusive funnel
// labels operators may filter on.
func ValidOnboardingState(state string) bool {
	return validOnboardingStates[strings.TrimSpace(state)]
}

// ListOnboardingAttempts returns every referral redemption and bootstrap
// identity row, outer-joined on provider_id. Callers overlay presence
// separately. The query never selects invite codes, digests, or key material.
func (s *Store) ListOnboardingAttempts(ctx context.Context) ([]OnboardingAttemptRecord, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, campaign, issuer_id, redeemed_at,
       bootstrap_created_at, expires_at, confirmed_at, operator_revoked_at
  FROM (
    SELECT i.provider_id AS provider_id,
           r.campaign AS campaign,
           r.issuer_id AS issuer_id,
           r.redeemed_at AS redeemed_at,
           i.created_at AS bootstrap_created_at,
           i.expires_at AS expires_at,
           i.confirmed_at AS confirmed_at,
           i.operator_revoked_at AS operator_revoked_at
      FROM provider_bootstrap_identities i
      LEFT JOIN referral_redemptions r ON r.provider_id = i.provider_id
    UNION ALL
    SELECT r.provider_id,
           r.campaign,
           r.issuer_id,
           r.redeemed_at,
           i.created_at,
           i.expires_at,
           i.confirmed_at,
           i.operator_revoked_at
      FROM referral_redemptions r
      LEFT JOIN provider_bootstrap_identities i ON i.provider_id = r.provider_id
     WHERE i.provider_id IS NULL
  )
 ORDER BY COALESCE(redeemed_at, bootstrap_created_at) DESC, provider_id ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []OnboardingAttemptRecord
	for rows.Next() {
		var (
			record             OnboardingAttemptRecord
			campaign, issuerID sql.NullString
		)
		if err := rows.Scan(
			&record.ProviderID,
			&campaign,
			&issuerID,
			&record.RedeemedAt,
			&record.BootstrapCreatedAt,
			&record.ExpiresAt,
			&record.ConfirmedAt,
			&record.OperatorRevokedAt,
		); err != nil {
			return nil, err
		}
		record.Campaign = nullStringValue(campaign)
		record.IssuerID = nullStringValue(issuerID)
		records = append(records, record)
	}
	return records, rows.Err()
}

// AssembleOnboardingAttempt derives the exclusive funnel state and copies
// non-secret timestamps. Presence defaults to unknown until OverlayPresence.
func AssembleOnboardingAttempt(record OnboardingAttemptRecord, now time.Time) OnboardingAttempt {
	attempt := OnboardingAttempt{
		ProviderID:         strings.TrimSpace(record.ProviderID),
		Campaign:           strings.TrimSpace(record.Campaign),
		IssuerID:           strings.TrimSpace(record.IssuerID),
		RedeemedAt:         nullStringValue(record.RedeemedAt),
		BootstrapCreatedAt: nullStringValue(record.BootstrapCreatedAt),
		ExpiresAt:          nullStringValue(record.ExpiresAt),
		ConfirmedAt:        nullStringValue(record.ConfirmedAt),
		OperatorRevokedAt:  nullStringValue(record.OperatorRevokedAt),
		Presence:           OnboardingPresenceUnknown,
	}
	attempt.State = DeriveOnboardingState(record, now, false)
	return attempt
}

// DeriveOnboardingState maps durable identity/redemption facts onto one
// exclusive operator state. connected only promotes a confirmed attempt to live.
func DeriveOnboardingState(record OnboardingAttemptRecord, now time.Time, connected bool) string {
	if record.OperatorRevokedAt.Valid && strings.TrimSpace(record.OperatorRevokedAt.String) != "" {
		return OnboardingStateFailedRevoked
	}
	if record.ConfirmedAt.Valid && strings.TrimSpace(record.ConfirmedAt.String) != "" {
		if connected {
			return OnboardingStateLive
		}
		return OnboardingStateConfirmed
	}
	if record.ExpiresAt.Valid {
		if expiresAt, err := time.Parse(time.RFC3339, record.ExpiresAt.String); err == nil && expiresAt.After(now) {
			return OnboardingStatePending
		}
	}
	return OnboardingStateFailedExpired
}

// OverlayPresence applies live/last-known signals. A confirmed connected
// provider becomes live. Unconfirmed attempts stay pending/expired even if a
// stale last-known row exists.
func OverlayPresence(attempt OnboardingAttempt, presence OnboardingPresence, now time.Time, record OnboardingAttemptRecord) OnboardingAttempt {
	if presence.Connected {
		attempt.Presence = OnboardingPresenceConnected
	} else if strings.TrimSpace(presence.LastSeenAt) != "" || strings.TrimSpace(presence.LastHeartbeatAt) != "" || strings.TrimSpace(presence.LastEventAt) != "" {
		attempt.Presence = OnboardingPresenceOffline
	} else {
		attempt.Presence = OnboardingPresenceUnknown
	}
	attempt.LastSeenAt = strings.TrimSpace(presence.LastSeenAt)
	attempt.LastHeartbeatAt = strings.TrimSpace(presence.LastHeartbeatAt)
	attempt.LastEventKind = strings.TrimSpace(presence.LastEventKind)
	attempt.LastEventOutcome = strings.TrimSpace(presence.LastEventOutcome)
	attempt.LastEventAt = strings.TrimSpace(presence.LastEventAt)
	attempt.LastFailureReason = strings.TrimSpace(presence.LastFailureReason)
	attempt.State = DeriveOnboardingState(record, now, presence.Connected)
	return attempt
}

// SummarizeOnboardingAttempts counts exclusive states across the full set.
func SummarizeOnboardingAttempts(attempts []OnboardingAttempt) OnboardingFunnelSummary {
	var summary OnboardingFunnelSummary
	for _, attempt := range attempts {
		switch attempt.State {
		case OnboardingStatePending:
			summary.Pending++
		case OnboardingStateConfirmed:
			summary.Confirmed++
		case OnboardingStateLive:
			summary.Live++
		case OnboardingStateFailedExpired:
			summary.FailedExpired++
		case OnboardingStateFailedRevoked:
			summary.FailedRevoked++
		}
	}
	return summary
}

// OnboardingSortKey is the list order: newest redemption/bootstrap first, then
// provider_id ascending. It matches ListOnboardingAttempts SQL ORDER BY.
func OnboardingSortKey(attempt OnboardingAttempt) (ts, id string) {
	ts = strings.TrimSpace(attempt.RedeemedAt)
	if ts == "" {
		ts = strings.TrimSpace(attempt.BootstrapCreatedAt)
	}
	return ts, strings.TrimSpace(attempt.ProviderID)
}

func onboardingAfterCursor(attempt OnboardingAttempt, afterTS, afterID string) bool {
	ts, id := OnboardingSortKey(attempt)
	if ts < afterTS {
		return true
	}
	return ts == afterTS && id > afterID
}

// PageOnboardingAttempts applies an exclusive-state filter, then a stable
// (after_ts, after_id) cursor, then limit. nextTS/nextID are set when more
// matching rows remain.
func PageOnboardingAttempts(attempts []OnboardingAttempt, filter string, limit int, afterTS, afterID string) (page []OnboardingAttempt, nextTS, nextID string) {
	if limit <= 0 {
		return nil, "", ""
	}
	filter = strings.TrimSpace(filter)
	afterTS = strings.TrimSpace(afterTS)
	afterID = strings.TrimSpace(afterID)
	page = make([]OnboardingAttempt, 0, limit)
	for _, attempt := range attempts {
		if filter != "" && filter != "all" && attempt.State != filter {
			continue
		}
		if afterTS != "" && afterID != "" && !onboardingAfterCursor(attempt, afterTS, afterID) {
			continue
		}
		if len(page) == limit {
			ts, id := OnboardingSortKey(page[len(page)-1])
			return page, ts, id
		}
		page = append(page, attempt)
	}
	return page, "", ""
}

func nullStringValue(value sql.NullString) string {
	if !value.Valid {
		return ""
	}
	return strings.TrimSpace(value.String)
}
