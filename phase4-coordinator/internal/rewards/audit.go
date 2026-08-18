package rewards

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	AuditEventMalibuAccrualInserted       = "malibu_accrual_inserted"
	AuditEventMalibuHoldApplied           = "malibu_hold_applied"
	AuditEventMalibuHoldCleared           = "malibu_hold_cleared"
	AuditEventWalletDailyCapApplied       = "wallet_daily_cap_applied"
	AuditEventWalletBindProjected         = "wallet_bind_projected"
	AuditEventTrustTierPromoted           = "trust_tier_promoted"
	AuditEventTrustTierDemoted            = "trust_tier_demoted"
	AuditEventWithdrawalCandidateSelected = "withdrawal_candidate_selected"
	AuditEventWithdrawalCandidateSkipped  = "withdrawal_candidate_skipped"
	AuditEventEligibilityReasonChanged    = "eligibility_reason_changed"
)

const (
	defaultAuditLimit = 25
	maxAuditLimit     = 100
)

type auditWriter interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}

type RewardAuditInsert struct {
	ProviderID           string
	OccurredAt           time.Time
	EventType            string
	LedgerID             sql.NullInt64
	AmountMALIBU         sql.NullString
	WithdrawalHoldReason sql.NullString
	TrustTier            sql.NullString
	SourceReason         sql.NullString
	SafeSummary          string
	OperatorCorrelation  map[string]string
}

type RewardAuditEvent struct {
	ID                   int64             `json:"-"`
	EventID              string            `json:"id"`
	ProviderID           string            `json:"provider_id,omitempty"`
	OccurredAt           time.Time         `json:"occurred_at"`
	EventType            string            `json:"event_type"`
	LedgerID             *int64            `json:"ledger_id,omitempty"`
	AmountMALIBU         string            `json:"amount_malibu,omitempty"`
	WithdrawalHoldReason string            `json:"withdrawal_hold_reason,omitempty"`
	TrustTier            string            `json:"trust_tier,omitempty"`
	SourceReason         string            `json:"source_reason,omitempty"`
	SafeSummary          string            `json:"summary"`
	OperatorCorrelation  map[string]string `json:"operator_correlation,omitempty"`
}

type RewardAuditPage struct {
	Events       []RewardAuditEvent `json:"events"`
	NextBeforeID string             `json:"next_before_id,omitempty"`
}

type RewardAuditQuery struct {
	ProviderID      string
	Limit           int
	BeforeID        int64
	IncludeProvider bool
	IncludeOperator bool
}

func InsertRewardAuditEvent(ctx context.Context, db *sql.DB, evt RewardAuditInsert) error {
	if db == nil {
		return errors.New("reward audit db is required")
	}
	_, err := insertRewardAuditEvent(ctx, db, evt)
	return err
}

func insertRewardAuditEvent(ctx context.Context, q auditWriter, evt RewardAuditInsert) (int64, error) {
	if strings.TrimSpace(evt.ProviderID) == "" {
		return 0, errors.New("provider_id is required")
	}
	if strings.TrimSpace(evt.EventType) == "" {
		return 0, errors.New("event_type is required")
	}
	if strings.TrimSpace(evt.SafeSummary) == "" {
		return 0, errors.New("safe_summary is required")
	}
	occurredAt := evt.OccurredAt
	if occurredAt.IsZero() {
		occurredAt = time.Now().UTC()
	}
	correlation := evt.OperatorCorrelation
	if correlation == nil {
		correlation = map[string]string{}
	}
	correlationJSON, err := json.Marshal(correlation)
	if err != nil {
		return 0, fmt.Errorf("marshal operator correlation: %w", err)
	}
	var id int64
	err = q.QueryRowContext(ctx, `
        INSERT INTO malibu_reward_audit_events
            (provider_id, occurred_at, event_type, ledger_id, amount_malibu,
             withdrawal_hold_reason, trust_tier, source_reason, safe_summary,
             operator_correlation)
        VALUES ($1, $2, $3, $4, $5::NUMERIC(24,8),
                $6, $7, $8, $9, $10::jsonb)
        RETURNING id
    `, evt.ProviderID, occurredAt, evt.EventType, nullInt64(evt.LedgerID),
		nullStringValue(evt.AmountMALIBU), nullStringValue(evt.WithdrawalHoldReason),
		nullStringValue(evt.TrustTier), nullStringValue(evt.SourceReason),
		evt.SafeSummary, string(correlationJSON)).Scan(&id)
	if err != nil {
		return 0, err
	}
	return id, nil
}

func QueryRewardAuditEvents(ctx context.Context, db *sql.DB, query RewardAuditQuery) (RewardAuditPage, error) {
	if db == nil {
		return RewardAuditPage{}, errors.New("reward audit db is required")
	}
	if strings.TrimSpace(query.ProviderID) == "" {
		return RewardAuditPage{}, errors.New("provider_id is required")
	}
	limit := normalizeAuditLimit(query.Limit)
	rows, err := db.QueryContext(ctx, `
        SELECT id, provider_id, occurred_at, event_type, ledger_id,
               amount_malibu::TEXT, withdrawal_hold_reason, trust_tier,
               source_reason, safe_summary, operator_correlation::TEXT
          FROM malibu_reward_audit_events
         WHERE provider_id = $1
           AND ($2::BIGINT = 0 OR id < $2)
         ORDER BY id DESC
         LIMIT $3
    `, query.ProviderID, query.BeforeID, limit+1)
	if err != nil {
		return RewardAuditPage{}, err
	}
	defer rows.Close()

	events := make([]RewardAuditEvent, 0, limit)
	var nextBefore string
	for rows.Next() {
		var (
			id              int64
			providerID      string
			occurredAt      time.Time
			eventType       string
			ledgerID        sql.NullInt64
			amount          sql.NullString
			hold            sql.NullString
			tier            sql.NullString
			source          sql.NullString
			summary         string
			correlationText string
		)
		if err := rows.Scan(&id, &providerID, &occurredAt, &eventType, &ledgerID,
			&amount, &hold, &tier, &source, &summary, &correlationText); err != nil {
			return RewardAuditPage{}, err
		}
		if len(events) == limit {
			if len(events) > 0 {
				nextBefore = auditEventID(events[len(events)-1].ID)
			}
			continue
		}
		evt := RewardAuditEvent{
			ID:          id,
			EventID:     auditEventID(id),
			OccurredAt:  occurredAt.UTC(),
			EventType:   eventType,
			SafeSummary: summary,
		}
		if query.IncludeProvider {
			evt.ProviderID = providerID
		}
		if ledgerID.Valid {
			v := ledgerID.Int64
			evt.LedgerID = &v
		}
		if amount.Valid {
			evt.AmountMALIBU = amount.String
		}
		if hold.Valid {
			evt.WithdrawalHoldReason = hold.String
		}
		if tier.Valid {
			evt.TrustTier = tier.String
		}
		if source.Valid {
			evt.SourceReason = source.String
		}
		if query.IncludeOperator {
			var correlation map[string]string
			if err := json.Unmarshal([]byte(correlationText), &correlation); err != nil {
				return RewardAuditPage{}, fmt.Errorf("decode operator correlation: %w", err)
			}
			evt.OperatorCorrelation = correlation
		}
		events = append(events, evt)
	}
	if err := rows.Err(); err != nil {
		return RewardAuditPage{}, err
	}
	return RewardAuditPage{Events: events, NextBeforeID: nextBefore}, nil
}

func normalizeAuditLimit(limit int) int {
	if limit <= 0 {
		return defaultAuditLimit
	}
	if limit > maxAuditLimit {
		return maxAuditLimit
	}
	return limit
}

func ParseAuditLimit(raw string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return defaultAuditLimit, nil
	}
	limit, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || limit <= 0 || limit > maxAuditLimit {
		return 0, fmt.Errorf("limit must be an integer from 1 to %d", maxAuditLimit)
	}
	return limit, nil
}

func ParseAuditBeforeID(raw string) (int64, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, nil
	}
	raw = strings.TrimPrefix(raw, "mra_")
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || id <= 0 {
		return 0, errors.New("before_id must be a reward audit id")
	}
	return id, nil
}

func auditEventID(id int64) string {
	return fmt.Sprintf("mra_%d", id)
}

func nullStringValue(ns sql.NullString) interface{} {
	if ns.Valid {
		return ns.String
	}
	return nil
}

func nullInt64(ns sql.NullInt64) interface{} {
	if ns.Valid {
		return ns.Int64
	}
	return nil
}

func auditAccrualInserted(ctx context.Context, tx *sql.Tx, providerID string, ledgerID int64, amount, hold, tier, reason, externalRef string, at time.Time) error {
	correlation := auditCorrelation(ledgerID, reason, externalRef)
	return auditWithHold(ctx, tx, RewardAuditInsert{
		ProviderID:           providerID,
		OccurredAt:           at,
		EventType:            AuditEventMalibuAccrualInserted,
		LedgerID:             sql.NullInt64{Int64: ledgerID, Valid: true},
		AmountMALIBU:         sql.NullString{String: amount, Valid: amount != ""},
		WithdrawalHoldReason: sql.NullString{String: hold, Valid: hold != ""},
		TrustTier:            sql.NullString{String: tier, Valid: tier != ""},
		SourceReason:         sql.NullString{String: reason, Valid: reason != ""},
		SafeSummary:          fmt.Sprintf("MALIBU accrual recorded: %s MALIBU.", amount),
		OperatorCorrelation:  correlation,
	})
}

func auditHoldApplied(ctx context.Context, tx *sql.Tx, providerID string, ledgerID int64, amount, hold, tier, reason, externalRef string, at time.Time) error {
	return auditWithHold(ctx, tx, RewardAuditInsert{
		ProviderID:           providerID,
		OccurredAt:           at,
		EventType:            AuditEventMalibuHoldApplied,
		LedgerID:             sql.NullInt64{Int64: ledgerID, Valid: true},
		AmountMALIBU:         sql.NullString{String: amount, Valid: amount != ""},
		WithdrawalHoldReason: sql.NullString{String: hold, Valid: true},
		TrustTier:            sql.NullString{String: tier, Valid: tier != ""},
		SourceReason:         sql.NullString{String: reason, Valid: reason != ""},
		SafeSummary:          holdSummary(hold),
		OperatorCorrelation:  auditCorrelation(ledgerID, reason, externalRef),
	})
}

func auditWalletDailyCapApplied(ctx context.Context, tx *sql.Tx, providerID string, ledgerID int64, amount, hold, tier, reason, externalRef string, at time.Time) error {
	return auditWithHold(ctx, tx, RewardAuditInsert{
		ProviderID:           providerID,
		OccurredAt:           at,
		EventType:            AuditEventWalletDailyCapApplied,
		LedgerID:             sql.NullInt64{Int64: ledgerID, Valid: true},
		AmountMALIBU:         sql.NullString{String: amount, Valid: amount != ""},
		WithdrawalHoldReason: sql.NullString{String: hold, Valid: true},
		TrustTier:            sql.NullString{String: tier, Valid: tier != ""},
		SourceReason:         sql.NullString{String: reason, Valid: reason != ""},
		SafeSummary:          "Wallet daily cap applied; this accrual is visible but not withdrawable yet.",
		OperatorCorrelation:  auditCorrelation(ledgerID, reason, externalRef),
	})
}

func auditHoldCleared(ctx context.Context, tx *sql.Tx, providerID string, ledgerID int64, amount, hold, tier, reason string, at time.Time) error {
	return auditWithHold(ctx, tx, RewardAuditInsert{
		ProviderID:           providerID,
		OccurredAt:           at,
		EventType:            AuditEventMalibuHoldCleared,
		LedgerID:             sql.NullInt64{Int64: ledgerID, Valid: true},
		AmountMALIBU:         sql.NullString{String: amount, Valid: amount != ""},
		WithdrawalHoldReason: sql.NullString{String: hold, Valid: hold != ""},
		TrustTier:            sql.NullString{String: tier, Valid: tier != ""},
		SourceReason:         sql.NullString{String: reason, Valid: reason != ""},
		SafeSummary:          fmt.Sprintf("Reward hold cleared: %s.", hold),
		OperatorCorrelation:  auditCorrelation(ledgerID, reason, ""),
	})
}

func auditTrustTierChangedTx(ctx context.Context, tx *sql.Tx, providerID, tier string, at time.Time) error {
	eventType := AuditEventTrustTierPromoted
	summary := "Provider promoted to trusted; new eligible accruals can become withdrawable."
	if tier == TierProvisional {
		eventType = AuditEventTrustTierDemoted
		summary = "Provider demoted to provisional; new accruals are held during requalification."
	}
	return auditWithHold(ctx, tx, RewardAuditInsert{
		ProviderID:          providerID,
		OccurredAt:          at,
		EventType:           eventType,
		TrustTier:           sql.NullString{String: tier, Valid: tier != ""},
		SafeSummary:         summary,
		OperatorCorrelation: map[string]string{"transition": eventType},
	})
}

func auditWithHold(ctx context.Context, tx *sql.Tx, evt RewardAuditInsert) error {
	_, err := insertRewardAuditEvent(ctx, tx, evt)
	return err
}

func auditCorrelation(ledgerID int64, reason, externalRef string) map[string]string {
	out := map[string]string{
		"ledger_id": fmt.Sprintf("%d", ledgerID),
	}
	if reason != "" {
		out["source_reason"] = reason
	}
	if externalRef != "" {
		out["external_ref"] = externalRef
	}
	return out
}

func holdSummary(hold string) string {
	switch hold {
	case HoldTrustTierProvisional:
		return "Reward hold applied because the provider is provisional."
	case HoldPerWalletDailyCap:
		return "Reward hold applied because the bound wallet reached the daily cap."
	case HoldDemotionCooldown:
		return "Reward hold applied during demotion cooldown."
	default:
		return "Reward hold applied."
	}
}
