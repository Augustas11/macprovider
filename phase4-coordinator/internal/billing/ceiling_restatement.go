package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// SPEC-005 §7.5b one-time ceiling restatement.
//
// Before SPEC-005 v0.6.18 a successful non-streaming attempt recorded
// ceil(body_bytes/16) as its completion ceiling, a lower bound on tokens, so
// verified-receipt re-pricing clamped honest receipt counts. The
// restatement re-runs the verified-receipt sync computation for those
// unsettled rows against the ceiling the superseded estimate implies under
// the body-bytes basis.

const (
	ceilingRestatementPath  = "/admin/ledger/ceiling-restatement"
	eventCeilingRestatement = "ledger_ceiling_restatement"
	// supersededNonStreamBytesPerToken is the divisor the superseded
	// non-streaming estimate used (tier2.output_bytes_per_token_ceiling
	// default).
	supersededNonStreamBytesPerToken = int64(16)
	defaultCeilingRestatementLimit   = 200
	maxCeilingRestatementLimit       = 1000
)

// CeilingRestatementInput is one operator-triggered restatement batch.
type CeilingRestatementInput struct {
	OperatorID string
	Reason     string
	From, To   time.Time
	DryRun     bool
	Limit      int
}

// CeilingRestatementRow is one restated (or, in a dry run, restatable) row.
type CeilingRestatementRow struct {
	RequestCreditID int64  `json:"request_credit_id"`
	RequestID       string `json:"request_id"`
	AttemptN        int64  `json:"attempt_n"`
	ProviderID      string `json:"provider_id"`
	OldEstimate     *int64 `json:"old_estimated_completion_tokens"`
	NewEstimate     *int64 `json:"new_estimated_completion_tokens"`
	OldUsageSource  string `json:"old_usage_source"`
	NewUsageSource  string `json:"new_usage_source"`
	OldGross        int64  `json:"old_gross_credits"`
	NewGross        int64  `json:"new_gross_credits"`
	OldProvider     int64  `json:"old_provider_credits"`
	NewProvider     int64  `json:"new_provider_credits"`
	OldOperator     int64  `json:"old_operator_credits"`
	NewOperator     int64  `json:"new_operator_credits"`
}

// CeilingRestatementResult summarizes a batch. More reports that rows past
// Limit still match the predicate.
type CeilingRestatementResult struct {
	DryRun        bool                    `json:"dry_run"`
	WindowFromUTC string                  `json:"window_from_utc"`
	WindowToUTC   string                  `json:"window_to_utc"`
	Candidates    int                     `json:"candidates"`
	Restated      int                     `json:"restated"`
	Skipped       map[string]int          `json:"skipped"`
	GrossDelta    int64                   `json:"gross_credits_delta"`
	ProviderDelta int64                   `json:"provider_credits_delta"`
	OperatorDelta int64                   `json:"operator_credits_delta"`
	More          bool                    `json:"more"`
	Rows          []CeilingRestatementRow `json:"rows"`
}

// restatedNonStreamCeiling is the smallest body length consistent with a
// superseded estimate e = ceil(body/16), i.e. (e-1)*16+1 bytes, which is the
// body-bytes ceiling (one byte per token) that body earns under v0.6.18.
func restatedNonStreamCeiling(supersededEstimate int64) int64 {
	if supersededEstimate <= 0 {
		return 0
	}
	ceiling := (supersededEstimate-1)*supersededNonStreamBytesPerToken + 1
	if ceiling > maxBillableTokens {
		return maxBillableTokens
	}
	return ceiling
}

type ceilingRestatementCandidate struct {
	requestID  string
	attemptN   int64
	providerID string
	estimate   int64
}

// RestateNonStreamCeilings runs one bounded restatement batch in a single
// BEGIN IMMEDIATE transaction. A dry run computes the same rows and deltas
// and writes nothing.
func (s *Store) RestateNonStreamCeilings(ctx context.Context, in CeilingRestatementInput) (CeilingRestatementResult, error) {
	if !in.From.Before(in.To) {
		return CeilingRestatementResult{}, errors.New("ceiling restatement window: from must be before to")
	}
	limit := in.Limit
	if limit <= 0 {
		limit = defaultCeilingRestatementLimit
	}
	if limit > maxCeilingRestatementLimit {
		limit = maxCeilingRestatementLimit
	}
	from, to := sqliteTimeText(in.From), sqliteTimeText(in.To)
	var out CeilingRestatementResult
	err := sqliteutil.TransactObserved(ctx, s.db, "billing_ceiling_restatement", s.sqliteMetric, func(ctx context.Context, conn *sql.Conn) error {
		out = CeilingRestatementResult{DryRun: in.DryRun, WindowFromUTC: from, WindowToUTC: to, Skipped: map[string]int{}, Rows: []CeilingRestatementRow{}}
		candidates, err := ceilingRestatementCandidatesTx(ctx, conn, from, to, limit+1)
		if err != nil {
			return err
		}
		if len(candidates) > limit {
			candidates, out.More = candidates[:limit], true
		}
		out.Candidates = len(candidates)
		now := time.Now().UTC().Format(time.RFC3339Nano)
		for _, c := range candidates {
			row, found, err := loadVerifiedReceiptCreditRowTx(ctx, conn, c.requestID, c.attemptN, c.providerID)
			if err != nil {
				return err
			}
			if !found || !row.ledgerEstimate.Valid || row.ledgerEstimate.Int64 != c.estimate {
				out.Skipped["not_verified_payable"]++
				continue
			}
			ceiling := restatedNonStreamCeiling(c.estimate)
			plan, err := s.planVerifiedReceiptCreditTx(ctx, conn, row, &ceiling)
			if err != nil {
				return err
			}
			if plan.quarantineReason != "" {
				// The restatement never quarantines; the receipt sync and
				// reconcile own that decision.
				out.Skipped["would_quarantine"]++
				continue
			}
			var oldOperator int64
			if err := conn.QueryRowContext(ctx, `SELECT COALESCE(SUM(operator_credits), 0) FROM ledger_operator_credits WHERE request_credit_id = ?`, row.requestCreditID).Scan(&oldOperator); err != nil {
				return err
			}
			r := CeilingRestatementRow{
				RequestCreditID: row.requestCreditID,
				RequestID:       row.requestID,
				AttemptN:        row.attemptN,
				ProviderID:      row.providerID,
				OldEstimate:     intPtrFromNull(row.ledgerEstimate),
				NewEstimate:     plan.keptEstimate,
				OldUsageSource:  row.ledgerUsageSource,
				NewUsageSource:  plan.result.UsageSource,
				OldGross:        row.ledgerGross,
				NewGross:        plan.result.GrossCredits,
				OldProvider:     row.ledgerProvider,
				NewProvider:     plan.result.ProviderCredits,
				OldOperator:     oldOperator,
				NewOperator:     plan.result.OperatorCredits,
			}
			if r.NewGross == r.OldGross && r.NewProvider == r.OldProvider && r.NewOperator == r.OldOperator && r.NewUsageSource == r.OldUsageSource {
				out.Skipped["unchanged"]++
				continue
			}
			if !in.DryRun {
				applied, err := applyVerifiedReceiptCreditTx(ctx, conn, row.requestCreditID, plan)
				if err != nil {
					return err
				}
				if !applied {
					return fmt.Errorf("ceiling restatement: request credit %d no longer unsettled", row.requestCreditID)
				}
				if err := insertCeilingRestatementAuditTx(ctx, conn, in, from, to, now, r); err != nil {
					return err
				}
			}
			out.Restated++
			out.GrossDelta += r.NewGross - r.OldGross
			out.ProviderDelta += r.NewProvider - r.OldProvider
			out.OperatorDelta += r.NewOperator - r.OldOperator
			out.Rows = append(out.Rows, r)
		}
		return nil
	})
	if err != nil {
		return CeilingRestatementResult{}, err
	}
	return out, nil
}

// ceilingRestatementCandidatesTx selects unsettled, unquarantined,
// enforce-mode non-streaming rows in [from, to) whose stored estimate
// clamped a larger completion and that no earlier restatement touched.
func ceilingRestatementCandidatesTx(ctx context.Context, conn *sql.Conn, from, to string, limit int) ([]ceilingRestatementCandidate, error) {
	rows, err := conn.QueryContext(ctx, `
SELECT lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.estimated_completion_tokens
  FROM ledger_request_credits lrc
 WHERE lrc.settled = 0
   AND lrc.settlement_id IS NULL
   AND lrc.quarantined = 0
   AND lrc.settlement_policy_mode = 'enforce'
   AND lrc.stream = 0
   AND lrc.usage_source = 'byte_estimated'
   AND lrc.estimated_completion_tokens IS NOT NULL
   AND lrc.completion_tokens IS NOT NULL
   AND lrc.estimated_completion_tokens < lrc.completion_tokens
   AND `+sqliteTimeRange("lrc.ts_utc")+`
   AND NOT EXISTS (
       SELECT 1 FROM audit_log a
        WHERE a.event_type = '`+eventCeilingRestatement+`'
          AND json_extract(a.payload_json, '$.request_credit_id') = lrc.id
   )
 ORDER BY lrc.id
 LIMIT ?`, from, to, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ceilingRestatementCandidate
	for rows.Next() {
		var c ceilingRestatementCandidate
		if err := rows.Scan(&c.requestID, &c.attemptN, &c.providerID, &c.estimate); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func insertCeilingRestatementAuditTx(ctx context.Context, conn *sql.Conn, in CeilingRestatementInput, from, to, now string, r CeilingRestatementRow) error {
	payload, err := json.Marshal(map[string]any{
		"severity":                        "WARN",
		"operator_attribution":            operatorAttribution,
		"operator_id":                     in.OperatorID,
		"reason":                          in.Reason,
		"request_credit_id":               r.RequestCreditID,
		"request_id":                      r.RequestID,
		"attempt_n":                       r.AttemptN,
		"provider_id":                     r.ProviderID,
		"window_from_utc":                 from,
		"window_to_utc":                   to,
		"superseded_bytes_per_token":      supersededNonStreamBytesPerToken,
		"old_estimated_completion_tokens": r.OldEstimate,
		"new_estimated_completion_tokens": r.NewEstimate,
		"old_usage_source":                r.OldUsageSource,
		"new_usage_source":                r.NewUsageSource,
		"old_gross_credits":               r.OldGross,
		"new_gross_credits":               r.NewGross,
		"old_provider_credits":            r.OldProvider,
		"new_provider_credits":            r.NewProvider,
		"old_operator_credits":            r.OldOperator,
		"new_operator_credits":            r.NewOperator,
		"ts_utc":                          now,
	})
	if err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, ?, ?, ?)`, now, eventCeilingRestatement, r.ProviderID, string(payload))
	return err
}

type ceilingRestatementBody struct {
	OperatorID string `json:"operator_id"`
	Reason     string `json:"reason"`
	FromUTC    string `json:"from_utc"`
	ToUTC      string `json:"to_utc"`
	DryRun     *bool  `json:"dry_run"`
	Limit      int    `json:"limit"`
}

// ceilingRestatementHandler implements POST /admin/ledger/ceiling-restatement.
// The dispatcher has already enforced the flag gate, operator auth, admin
// rate limit, and method.
func (h *handler) ceilingRestatementHandler(w http.ResponseWriter, r *http.Request) {
	if ct := r.Header.Get("Content-Type"); !isJSONContentType(ct) {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "content-type must be application/json")
		return
	}
	if r.ContentLength > maxBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes+1)
	defer r.Body.Close()
	fields, ok := readStrictJSONObject(w, r, map[string]bool{"operator_id": true, "reason": true, "from_utc": true, "to_utc": true, "dry_run": true, "limit": true})
	if !ok {
		return
	}
	var body ceilingRestatementBody
	for _, key := range []string{"operator_id", "reason", "from_utc", "to_utc", "dry_run"} {
		if _, present := fields[key]; !present {
			writeValidationError(w, "missing_field", key+" is required")
			return
		}
	}
	raw, err := json.Marshal(fields)
	if err != nil || json.Unmarshal(raw, &body) != nil || body.DryRun == nil {
		writeError(w, http.StatusBadRequest, "bad_request", "operator_id, reason, from_utc, to_utc must be strings, dry_run a boolean, limit an integer")
		return
	}
	if strings.ContainsRune(body.OperatorID, utf8.RuneError) || strings.ContainsRune(body.Reason, utf8.RuneError) {
		writeValidationError(w, "invalid_utf8", "operator_id or reason contains invalid surrogate escape")
		return
	}
	if errCode := validateOperatorID(body.OperatorID); errCode != "" {
		writeValidationError(w, errCode, "operator_id rejected: "+errCode)
		return
	}
	if errCode := validateReason(body.Reason); errCode != "" {
		writeValidationError(w, errCode, "reason rejected: "+errCode)
		return
	}
	from, errFrom := time.Parse(time.RFC3339Nano, body.FromUTC)
	to, errTo := time.Parse(time.RFC3339Nano, body.ToUTC)
	if errFrom != nil || errTo != nil || !from.Before(to) {
		writeValidationError(w, "bad_window", "from_utc and to_utc must be RFC 3339 with from_utc before to_utc")
		return
	}
	if body.Limit < 0 || body.Limit > maxCeilingRestatementLimit {
		writeValidationError(w, "bad_limit", fmt.Sprintf("limit must be between 1 and %d", maxCeilingRestatementLimit))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	result, err := h.store.RestateNonStreamCeilings(ctx, CeilingRestatementInput{
		OperatorID: trimSpaceASCII(body.OperatorID),
		Reason:     trimSpaceASCII(body.Reason),
		From:       from,
		To:         to,
		DryRun:     *body.DryRun,
		Limit:      body.Limit,
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "ceiling restatement: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}
