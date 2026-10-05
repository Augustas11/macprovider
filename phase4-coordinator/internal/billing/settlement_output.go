package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

const (
	TerminalStateNormalDone                  = "normal_done"
	TerminalStateProviderError               = "provider_error"
	TerminalStateBuyerCancel                 = "buyer_cancel"
	TerminalStateGatewayTimeout              = "gateway_timeout"
	TerminalStateUpstreamTransportDisconnect = "upstream_transport_disconnect"

	UsageSourceCoordinatorObserved = "coordinator_observed"
	UsageSourceByteEstimated       = "byte_estimated"
	// UsageSourcePoolOperatorAttested is the SPEC-022-R012 pool-scoped usage
	// source: the pool operator's own reported usage, signed in its v0.4
	// receipt, trusted administratively under the pool's signed policy. It is
	// never coordinator_observed and never described as coordinator-verified.
	UsageSourcePoolOperatorAttested = "pool_operator_attested"
)

var terminalStatePattern = regexp.MustCompile(`^(normal_done|provider_error|buyer_cancel|gateway_timeout|upstream_transport_disconnect)$`)

var errSettlementAttemptOutputJournalPoison = errors.New("settlement attempt output journal poison")

type SettlementToolCall struct {
	ID        string
	Type      string
	Name      string
	Arguments string
}

type SettlementOutput struct {
	Content               string
	FinishReason          *string
	Available             bool
	OutputPrefixStartByte int64
	OutputPrefixEndByte   int64
	TerminalState         string
	TerminalStateTSUnixMS int64
	ToolCalls             []SettlementToolCall
	// ObservedInputTokens and ObservedOutputTokens are the attempt's observed
	// usage when its ledger row bills none of it: a buyer_cancel that delivered
	// nothing (SPEC-015 §N.6/§N.7). They are evidence only and are not part of
	// settlement_output_v1.
	ObservedInputTokens  *int64
	ObservedOutputTokens *int64
	// RelayBlindResponseSHA256 marks a SPEC-022 R-13 relay-blind attempt. It
	// is the lowercase hex SHA-256 of the exact response bytes the coordinator
	// received (R-3.5), and OutputPrefixEndByte-OutputPrefixStartByte is their
	// count. Such an output holds no content and is the attempt's output
	// hash: a relay-blind attempt never persists a plaintext output hash.
	RelayBlindResponseSHA256 string
}

type SettlementUsage struct {
	BillableInputTokens  int64
	BillableOutputTokens int64
	DeliveredOutputBytes int64
	ObservedInputTokens  int64
	ObservedOutputTokens int64
}

type SettlementAttemptOutput struct {
	AccountScope                  string
	RequestID                     string
	AttemptN                      int64
	ProviderID                    string
	Output                        SettlementOutput
	OutputAvailable               bool
	Usage                         SettlementUsage
	UsageSource                   string
	TerminalStateTSUnixMS         int64
	OverlappingOrDuplicate        bool
	SettlementOutputCanonicalJSON []byte
	UsageCanonicalJSON            []byte
	OutputHash                    string
	UsageHash                     string
}

type SettlementAttemptOutputMaterializationResult struct {
	SelectedRows            int
	MaterializedRows        int
	AlreadyMaterializedRows int
	PoisonedRows            int
}

type SettlementAttemptOutputJournalStats struct {
	PendingRows             int64
	PoisonedRows            int64
	RetainedPoisonedRows    int64
	OldestPendingCreatedAt  time.Time
	HasOldestPendingCreated bool
	OldestPendingAge        time.Duration
}

func (o SettlementOutput) Value() map[string]any {
	var finish any
	if o.FinishReason != nil {
		finish = *o.FinishReason
	}
	var toolCalls any
	if len(o.ToolCalls) > 0 {
		toolCalls = settlementToolCallsValue(o.ToolCalls)
	}
	return map[string]any{
		"content":                  o.Content,
		"finish_reason":            finish,
		"output_prefix_end_byte":   int64(o.OutputPrefixEndByte),
		"output_prefix_start_byte": int64(o.OutputPrefixStartByte),
		"terminal_state":           o.TerminalState,
		"tool_calls":               toolCalls,
	}
}

func (u SettlementUsage) Value() map[string]any {
	return map[string]any{
		"billable_input_tokens":  int64(u.BillableInputTokens),
		"billable_output_tokens": int64(u.BillableOutputTokens),
		"delivered_output_bytes": int64(u.DeliveredOutputBytes),
		"observed_input_tokens":  int64(u.ObservedInputTokens),
		"observed_output_tokens": int64(u.ObservedOutputTokens),
	}
}

func settlementToolCallsValue(calls []SettlementToolCall) []any {
	items := make([]any, 0, len(calls))
	for _, call := range calls {
		items = append(items, map[string]any{
			"id":   call.ID,
			"type": call.Type,
			"function": map[string]any{
				"name":      call.Name,
				"arguments": RawJSONString(call.Arguments),
			},
		})
	}
	return items
}

func SettlementDeliveredOutputBytes(content string) int64 {
	normalized := strings.ReplaceAll(content, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	return int64(len([]byte(norm.NFC.String(normalized))))
}

func (o SettlementOutput) Digest() (string, []byte, error) {
	if err := o.Validate(); err != nil {
		return "", nil, err
	}
	if o.RelayBlindResponseSHA256 != "" {
		return o.RelayBlindResponseSHA256, nil, nil
	}
	return CanonicalSHA256Hex(o.Value())
}

func (u SettlementUsage) Digest() (string, []byte, error) {
	if err := u.Validate(); err != nil {
		return "", nil, err
	}
	return CanonicalSHA256Hex(u.Value())
}

func (o SettlementOutput) Validate() error {
	if !terminalStatePattern.MatchString(o.TerminalState) {
		return fmt.Errorf("invalid terminal_state %q", o.TerminalState)
	}
	if o.OutputPrefixStartByte < 0 || o.OutputPrefixEndByte < o.OutputPrefixStartByte {
		return fmt.Errorf("invalid output byte range [%d,%d)", o.OutputPrefixStartByte, o.OutputPrefixEndByte)
	}
	if o.RelayBlindResponseSHA256 != "" {
		if !hex64Pattern.MatchString(o.RelayBlindResponseSHA256) {
			return fmt.Errorf("relay-blind response digest must be 64 lowercase hex chars")
		}
		if o.Content != "" || o.FinishReason != nil || len(o.ToolCalls) > 0 {
			return fmt.Errorf("relay-blind output must not carry content")
		}
		return nil
	}
	delivered := SettlementDeliveredOutputBytes(o.Content)
	if delivered != o.OutputPrefixEndByte-o.OutputPrefixStartByte {
		return fmt.Errorf("delivered bytes=%d does not match output byte range length=%d", delivered, o.OutputPrefixEndByte-o.OutputPrefixStartByte)
	}
	for _, call := range o.ToolCalls {
		if call.ID == "" || call.Type != "function" || call.Name == "" {
			return fmt.Errorf("invalid tool call")
		}
		if !json.Valid([]byte(call.Arguments)) {
			return fmt.Errorf("tool call arguments are not valid JSON")
		}
	}
	return nil
}

func (u SettlementUsage) Validate() error {
	values := []int64{
		u.BillableInputTokens,
		u.BillableOutputTokens,
		u.DeliveredOutputBytes,
		u.ObservedInputTokens,
		u.ObservedOutputTokens,
	}
	for _, value := range values {
		if value < 0 {
			return fmt.Errorf("usage value is negative")
		}
	}
	return nil
}

func (a SettlementAttemptOutput) Validate() error {
	if a.AccountScope == "" {
		return fmt.Errorf("account_scope is required")
	}
	if a.RequestID == "" {
		return fmt.Errorf("request_id is required")
	}
	if a.AttemptN < 0 {
		return fmt.Errorf("attempt_n must be nonnegative")
	}
	if a.ProviderID == "" {
		return fmt.Errorf("provider_id is required")
	}
	if !validUsageSource(a.UsageSource) {
		return fmt.Errorf("invalid usage_source %q", a.UsageSource)
	}
	if a.TerminalStateTSUnixMS <= 0 {
		return fmt.Errorf("terminal_state_ts_unix_ms is required")
	}
	if !a.OutputAvailable {
		if !terminalStatePattern.MatchString(a.Output.TerminalState) {
			return fmt.Errorf("invalid terminal_state %q", a.Output.TerminalState)
		}
		if a.Output.OutputPrefixStartByte != 0 || a.Output.OutputPrefixEndByte != 0 {
			return fmt.Errorf("unavailable output must have empty byte range")
		}
		if err := a.Usage.Validate(); err != nil {
			return err
		}
		if a.Usage.DeliveredOutputBytes != 0 {
			return fmt.Errorf("unavailable output must have zero delivered bytes")
		}
		return nil
	}
	if err := a.Output.Validate(); err != nil {
		return err
	}
	if err := a.Usage.Validate(); err != nil {
		return err
	}
	if a.Usage.DeliveredOutputBytes != a.Output.OutputPrefixEndByte-a.Output.OutputPrefixStartByte {
		return fmt.Errorf("usage delivered_output_bytes does not match output range")
	}
	return nil
}

func validUsageSource(value string) bool {
	switch value {
	case UsageSourceCoordinatorObserved, UsageSourceByteEstimated, UsageSourcePoolOperatorAttested:
		return true
	default:
		return false
	}
}

func nullableOutputString(value string, valid bool) any {
	if !valid {
		return nil
	}
	return value
}

// SettlementAttemptOutputExists reports whether this attempt already stored
// evidence. A deadline retry uses it so a commit the caller observed as a
// timeout is not written again with a new timestamp. The lookup matches the
// evidence unique key so another attempt or account cannot hide a missing row.
func (s *Store) SettlementAttemptOutputExists(ctx context.Context, accountScope, requestID string, attemptN int64, providerID string) (bool, error) {
	if s == nil || accountScope == "" || requestID == "" || providerID == "" || attemptN < 0 {
		return false, nil
	}
	var one int
	err := s.db.QueryRowContext(ctx, `
SELECT 1 FROM settlement_attempt_outputs
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?
LIMIT 1`, accountScope, requestID, attemptN, providerID).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// MarkSettlementOutputMissing records that a credited request has no
// settlement evidence. The credit amount is left unchanged and the row stays
// unquarantined here; a negotiated enforce attempt's credit is quarantined
// separately (QuarantineUndeliveredSettlementCredit). Callers filter on this
// reason when measuring provider revenue. It reports whether a credited row
// was marked: an uncredited attempt (a 502, a zero credit) has none.
func (s *Store) MarkSettlementOutputMissing(ctx context.Context, requestID string, attemptN int, providerID string) (bool, error) {
	if s == nil || requestID == "" || providerID == "" || attemptN < 0 {
		return false, nil
	}
	res, err := s.db.ExecContext(ctx, `
UPDATE ledger_request_credits
SET quarantine_reason = 'settlement_attempt_output_missing'
WHERE request_id = ? AND attempt_n = ? AND provider_id = ?
  AND status = 200
  AND provider_credits > 0
  AND quarantined = 0
  AND (quarantine_reason IS NULL OR quarantine_reason = '')`,
		requestID, attemptN, providerID)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// QuarantineUndeliveredSettlementCredit quarantines an unsettled provider
// credit whose settlement evidence failed after the buyer response was
// delivered and the buyer reservation was refunded (SPEC-022 v0.2.2 enforce
// mode). A quarantined row leaves spec022_payable_request_credits unless an
// operator force-credits it. The credit amount is kept for that review. The
// reason replaces MarkSettlementOutputMissing's informational reason so the
// finality lookup recognises it (UndeliveredSettlementQuarantineReasons). A
// credit whose attempt already has a closed verified verdict is never
// quarantined (UndeliveredQuarantineVerified).
// UndeliveredSettlementQuarantineReasons are the coordinator reasons a
// credit is quarantined with after a delivered attempt's settlement evidence
// failed (SPEC-022 v0.2.2). The finality lookup reports such an attempt as
// closed quarantined, so a gateway that never received the refund trailer
// still refunds instead of holding.
var UndeliveredSettlementQuarantineReasons = []string{
	"settlement_record_failed_after_delivery",
	"settlement_output_missing_after_credit",
	"settlement_finality_unset_after_delivery",
}

// UndeliveredQuarantineResult is what QuarantineUndeliveredSettlementCredit
// found.
type UndeliveredQuarantineResult int

const (
	// UndeliveredQuarantineNoCredit: no unsettled, unquarantined credit row
	// for the attempt and no verified verdict for it.
	UndeliveredQuarantineNoCredit UndeliveredQuarantineResult = iota
	// UndeliveredQuarantineQuarantined: the credit row is now quarantined.
	UndeliveredQuarantineQuarantined
	// UndeliveredQuarantineVerified: the attempt already has a closed
	// verified verdict, so its credit is legitimately payable and was left
	// alone.
	UndeliveredQuarantineVerified
	// UndeliveredQuarantineRelayBlindSettled: the attempt already has a
	// closed relay_blind_settled verdict under the SPEC-022 R-7.9 binding.
	// Its credit is payable and was left alone; it is never reported as
	// verified.
	UndeliveredQuarantineRelayBlindSettled
)

func (s *Store) QuarantineUndeliveredSettlementCredit(ctx context.Context, accountScope, requestID string, attemptN int, providerID, reason string) (UndeliveredQuarantineResult, error) {
	if s == nil || requestID == "" || providerID == "" || attemptN < 0 || reason == "" {
		return UndeliveredQuarantineNoCredit, nil
	}
	scopeHash := SettlementAccountScopeHash(accountScope)
	res, err := s.db.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = CASE
           WHEN quarantine_reason IS NULL OR quarantine_reason IN ('', 'settlement_attempt_output_missing') THEN ?
           ELSE quarantine_reason END,
       updated_at_utc = ?
 WHERE request_id = ? AND attempt_n = ? AND provider_id = ?
   AND quarantined = 0
   AND settled = 0
   AND NOT EXISTS (
       SELECT 1 FROM settlement_receipt_verdicts srv
         JOIN settlement_route_snapshots srs
           ON srs.request_id = srv.request_id
          AND srs.attempt_n = srv.attempt_n
          AND srs.provider_id = srv.provider_id
          AND srs.route_snapshot_digest = srv.route_snapshot_digest
        WHERE srv.account_scope_hash = ?
          AND srv.request_id = ledger_request_credits.request_id
          AND srv.provider_id = ledger_request_credits.provider_id
          AND srv.closed = 1
          AND `+payableSettlementOutcomeSQL("srv", "srs")+`)`,
		reason, time.Now().UTC().Format(time.RFC3339Nano), requestID, attemptN, providerID, scopeHash)
	if err != nil {
		return UndeliveredQuarantineNoCredit, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return UndeliveredQuarantineNoCredit, err
	} else if n > 0 {
		return UndeliveredQuarantineQuarantined, nil
	}
	_, verified, err := s.SettlementAttemptEvidence(ctx, accountScope, requestID, providerID)
	if err != nil {
		return UndeliveredQuarantineNoCredit, err
	}
	if verified {
		return UndeliveredQuarantineVerified, nil
	}
	relayBlindSettled, err := s.boundRelayBlindSettledAttempt(ctx, accountScope, requestID, providerID)
	if err != nil {
		return UndeliveredQuarantineNoCredit, err
	}
	if relayBlindSettled {
		return UndeliveredQuarantineRelayBlindSettled, nil
	}
	return UndeliveredQuarantineNoCredit, nil
}

// boundRelayBlindSettledAttempt reports whether the request's attempt on
// providerID has a closed relay_blind_settled verdict under the SPEC-022
// R-7.9 binding, the only way that outcome is payable.
func (s *Store) boundRelayBlindSettledAttempt(ctx context.Context, accountScope, requestID, providerID string) (bool, error) {
	if s == nil {
		return false, nil
	}
	var settled bool
	err := s.db.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1 FROM settlement_receipt_verdicts srv
      JOIN settlement_route_snapshots srs
        ON srs.request_id = srv.request_id
       AND srs.attempt_n = srv.attempt_n
       AND srs.provider_id = srv.provider_id
       AND srs.route_snapshot_digest = srv.route_snapshot_digest
     WHERE srv.account_scope_hash = ? AND srv.request_id = ? AND srv.provider_id = ?
       AND srv.closed = 1
       AND srv.settlement_outcome = '`+SettlementOutcomeRelayBlindSettled+`'
       AND `+payableSettlementOutcomeSQL("srv", "srs")+`)`,
		SettlementAccountScopeHash(accountScope), requestID, providerID).Scan(&settled)
	return settled, err
}

// SettlementAttemptEvidence reports whether the request's attempt on
// providerID has a settlement attempt output and a closed verified verdict.
// Only the in-request recorder writes an attempt output, and an enforce
// credit is payable only with both (spec022_payable_request_credits).
func (s *Store) SettlementAttemptEvidence(ctx context.Context, accountScope, requestID, providerID string) (hasOutput, verified bool, err error) {
	if s == nil {
		return false, false, nil
	}
	err = s.db.QueryRowContext(ctx, `
SELECT
    EXISTS (SELECT 1 FROM settlement_attempt_outputs
             WHERE account_scope = ? AND request_id = ? AND provider_id = ?),
    EXISTS (SELECT 1 FROM settlement_receipt_verdicts
             WHERE account_scope_hash = ? AND request_id = ? AND provider_id = ?
               AND closed = 1 AND settlement_outcome = 'verified')`,
		accountScope, requestID, providerID,
		SettlementAccountScopeHash(accountScope), requestID, providerID).Scan(&hasOutput, &verified)
	return hasOutput, verified, err
}

type preparedSettlementAttemptOutput struct {
	attempt         SettlementAttemptOutput
	outputHash      string
	outputCanonical sql.NullString
	usageHash       string
	usageCanonical  string
	payloadHash     string
}

func prepareSettlementAttemptOutput(attempt SettlementAttemptOutput) (preparedSettlementAttemptOutput, error) {
	if err := attempt.Validate(); err != nil {
		return preparedSettlementAttemptOutput{}, err
	}
	outputHash := ""
	var outputCanonical sql.NullString
	var err error
	if attempt.OutputAvailable {
		var canonical []byte
		outputHash, canonical, err = attempt.Output.Digest()
		if err != nil {
			return preparedSettlementAttemptOutput{}, err
		}
		outputCanonical = sql.NullString{String: string(canonical), Valid: canonical != nil}
	}
	usageHash, usageCanonical, err := attempt.Usage.Digest()
	if err != nil {
		return preparedSettlementAttemptOutput{}, err
	}
	payloadHash, _, err := CanonicalSHA256Hex(map[string]any{
		"account_scope":             attempt.AccountScope,
		"request_id":                attempt.RequestID,
		"attempt_n":                 attempt.AttemptN,
		"provider_id":               attempt.ProviderID,
		"terminal_state":            attempt.Output.TerminalState,
		"terminal_state_ts_unix_ms": attempt.TerminalStateTSUnixMS,
		"output_available":          attempt.OutputAvailable,
		"output_prefix_start_byte":  attempt.Output.OutputPrefixStartByte,
		"output_prefix_end_byte":    attempt.Output.OutputPrefixEndByte,
		"output_hash":               nullableOutputString(outputHash, attempt.OutputAvailable),
		"usage_hash":                usageHash,
		"usage_canonical_json":      string(usageCanonical),
		"usage_source":              attempt.UsageSource,
		"overlapping_or_duplicate":  attempt.OverlappingOrDuplicate,
	})
	if err != nil {
		return preparedSettlementAttemptOutput{}, err
	}
	return preparedSettlementAttemptOutput{
		attempt:         attempt,
		outputHash:      outputHash,
		outputCanonical: outputCanonical,
		usageHash:       usageHash,
		usageCanonical:  string(usageCanonical),
		payloadHash:     payloadHash,
	}, nil
}

func (s *Store) InsertSettlementAttemptOutput(ctx context.Context, attempt SettlementAttemptOutput) (string, error) {
	prepared, err := prepareSettlementAttemptOutput(attempt)
	if err != nil {
		return "", err
	}
	// BEGIN IMMEDIATE (the money-path pattern): the overlap read and the
	// insert share one write lock taken up front, so a writer on another
	// handle to this file (routeSnapshotDB) waits in busy_timeout instead of
	// failing the deferred read-to-write upgrade with SQLITE_BUSY_SNAPSHOT.
	err = sqliteutil.TransactObserved(ctx, s.db, "settlement_attempt_output", s.sqliteMetric, func(ctx context.Context, conn *sql.Conn) error {
		_, err := insertSettlementAttemptOutputConn(ctx, conn, prepared, false, s.nowUTC())
		return err
	})
	if err != nil {
		return "", err
	}
	return prepared.outputHash, nil
}

func insertSettlementAttemptOutputConn(ctx context.Context, conn *sql.Conn, prepared preparedSettlementAttemptOutput, persistOutputCanonical bool, now time.Time) (bool, error) {
	attempt := prepared.attempt
	var overlapCount int
	if attempt.OutputAvailable {
		if err := conn.QueryRowContext(ctx, `
SELECT COUNT(*)
FROM settlement_attempt_outputs
WHERE account_scope = ?
  AND request_id = ?
  AND NOT (attempt_n = ? AND provider_id = ?)
  AND (
      NOT (output_prefix_end_byte <= ? OR output_prefix_start_byte >= ?)
      OR output_hash = ?
      OR (attempt_n < ? AND output_prefix_start_byte > ?)
      OR (attempt_n > ? AND output_prefix_start_byte < ?)
  )`,
			attempt.AccountScope, attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
			attempt.Output.OutputPrefixStartByte, attempt.Output.OutputPrefixEndByte, prepared.outputHash,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
		).Scan(&overlapCount); err != nil {
			return false, err
		}
	}
	overlap := attempt.OverlappingOrDuplicate || overlapCount > 0
	outputCanonical := any(nil)
	if persistOutputCanonical && prepared.outputCanonical.Valid {
		outputCanonical = prepared.outputCanonical.String
	}
	res, err := conn.ExecContext(ctx, `
INSERT INTO settlement_attempt_outputs (
    account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms, output_available,
    output_prefix_start_byte, output_prefix_end_byte, output_hash,
    settlement_output_canonical_json, usage_hash, usage_canonical_json,
    usage_source, overlapping_or_duplicate, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(account_scope, request_id, attempt_n, provider_id) DO NOTHING`,
		attempt.AccountScope,
		attempt.RequestID,
		attempt.AttemptN,
		attempt.ProviderID,
		attempt.Output.TerminalState,
		attempt.TerminalStateTSUnixMS,
		boolInt(attempt.OutputAvailable),
		attempt.Output.OutputPrefixStartByte,
		attempt.Output.OutputPrefixEndByte,
		nullableOutputString(prepared.outputHash, attempt.OutputAvailable),
		outputCanonical,
		prepared.usageHash,
		prepared.usageCanonical,
		attempt.UsageSource,
		boolInt(overlap),
		now.UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		return false, err
	}
	if overlap {
		if _, err := conn.ExecContext(ctx, `
UPDATE settlement_attempt_outputs
SET overlapping_or_duplicate = 1
WHERE account_scope = ?
  AND request_id = ?
  AND output_available = 1
  AND NOT (attempt_n = ? AND provider_id = ?)
  AND (
      NOT (output_prefix_end_byte <= ? OR output_prefix_start_byte >= ?)
      OR output_hash = ?
      OR (attempt_n < ? AND output_prefix_start_byte > ?)
      OR (attempt_n > ? AND output_prefix_start_byte < ?)
  )`,
			attempt.AccountScope, attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
			attempt.Output.OutputPrefixStartByte, attempt.Output.OutputPrefixEndByte, prepared.outputHash,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
		); err != nil {
			return false, err
		}
	}
	if rows, err := res.RowsAffected(); err == nil && rows > 0 {
		return true, nil
	}
	if overlap {
		if _, err := conn.ExecContext(ctx, `
UPDATE settlement_attempt_outputs
SET overlapping_or_duplicate = 1
WHERE account_scope = ?
  AND request_id = ?
  AND attempt_n = ?
  AND provider_id = ?`,
			attempt.AccountScope, attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
		); err != nil {
			return false, err
		}
	}
	var existing struct {
		TerminalState         string
		TerminalStateTSUnixMS int64
		OutputAvailable       int
		Start                 int64
		End                   int64
		OutputHash            sql.NullString
		UsageHash             string
		UsageCanonical        string
		UsageSource           string
		Overlap               int
	}
	err = conn.QueryRowContext(ctx, `
SELECT terminal_state, terminal_state_ts_unix_ms, output_available, output_prefix_start_byte,
       output_prefix_end_byte, output_hash,
       usage_hash, usage_canonical_json, usage_source, overlapping_or_duplicate
FROM settlement_attempt_outputs
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		attempt.AccountScope, attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
	).Scan(
		&existing.TerminalState,
		&existing.TerminalStateTSUnixMS,
		&existing.OutputAvailable,
		&existing.Start,
		&existing.End,
		&existing.OutputHash,
		&existing.UsageHash,
		&existing.UsageCanonical,
		&existing.UsageSource,
		&existing.Overlap,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return false, fmt.Errorf("%w: materialized row disappeared", errSettlementAttemptOutputJournalPoison)
		}
		return false, err
	}
	overlapCompatible := existing.Overlap == boolInt(overlap) || (existing.Overlap == 1 && !overlap)
	if existing.TerminalState != attempt.Output.TerminalState ||
		existing.TerminalStateTSUnixMS != attempt.TerminalStateTSUnixMS ||
		existing.OutputAvailable != boolInt(attempt.OutputAvailable) ||
		existing.Start != attempt.Output.OutputPrefixStartByte ||
		existing.End != attempt.Output.OutputPrefixEndByte ||
		existing.OutputHash.Valid != attempt.OutputAvailable ||
		existing.OutputHash.String != prepared.outputHash ||
		existing.UsageHash != prepared.usageHash ||
		existing.UsageCanonical != prepared.usageCanonical ||
		existing.UsageSource != attempt.UsageSource ||
		!overlapCompatible {
		return false, fmt.Errorf("%w: immutable materialized output conflict", errSettlementAttemptOutputJournalPoison)
	}
	return false, nil
}

func (s *Store) JournalSettlementAttemptOutputConn(ctx context.Context, conn *sql.Conn, attempt SettlementAttemptOutput) error {
	if s == nil {
		return fmt.Errorf("billing store is nil")
	}
	if conn == nil {
		return fmt.Errorf("settlement attempt output journal connection is required")
	}
	prepared, err := prepareSettlementAttemptOutput(attempt)
	if err != nil {
		return err
	}
	now := s.nowUTC().Format(time.RFC3339Nano)
	res, err := conn.ExecContext(ctx, `
	INSERT INTO settlement_attempt_output_journal (
    account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_available, output_prefix_start_byte, output_prefix_end_byte, output_hash,
    usage_hash, usage_canonical_json, usage_source, overlapping_or_duplicate, payload_hash, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(account_scope, request_id, attempt_n, provider_id) DO NOTHING`,
		attempt.AccountScope,
		attempt.RequestID,
		attempt.AttemptN,
		attempt.ProviderID,
		attempt.Output.TerminalState,
		attempt.TerminalStateTSUnixMS,
		boolInt(attempt.OutputAvailable),
		attempt.Output.OutputPrefixStartByte,
		attempt.Output.OutputPrefixEndByte,
		nullableOutputString(prepared.outputHash, attempt.OutputAvailable),
		prepared.usageHash,
		prepared.usageCanonical,
		attempt.UsageSource,
		boolInt(attempt.OverlappingOrDuplicate),
		prepared.payloadHash,
		now,
	)
	if err != nil {
		return err
	}
	if rows, err := res.RowsAffected(); err == nil && rows > 0 {
		return nil
	}
	var existingHash string
	err = conn.QueryRowContext(ctx, `
SELECT payload_hash
  FROM settlement_attempt_output_journal
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		attempt.AccountScope, attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
	).Scan(&existingHash)
	if err != nil {
		if err == sql.ErrNoRows {
			return fmt.Errorf("%w: journal row disappeared", errSettlementAttemptOutputJournalPoison)
		}
		return err
	}
	if existingHash != prepared.payloadHash {
		_, _ = conn.ExecContext(ctx, `
UPDATE settlement_attempt_output_journal
   SET poisoned_at_utc = COALESCE(poisoned_at_utc, ?),
       poison_reason = CASE WHEN poison_reason = '' THEN ? ELSE poison_reason END,
       last_materialize_error = CASE WHEN last_materialize_error = '' THEN ? ELSE last_materialize_error END
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
			now,
			"settlement attempt output journal immutable conflict",
			"settlement attempt output journal immutable conflict",
			attempt.AccountScope, attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
		)
		return fmt.Errorf("%w: immutable journal conflict", errSettlementAttemptOutputJournalPoison)
	}
	return nil
}

func (s *Store) MaterializeSettlementAttemptOutputFor(ctx context.Context, id SettlementReceiptIdentity) (bool, error) {
	if s == nil {
		return false, fmt.Errorf("billing store is nil")
	}
	if err := id.validate(); err != nil {
		return false, err
	}
	var materialized bool
	err := sqliteutil.TransactObserved(ctx, s.db, "settlement_attempt_output_journal_materialize", s.sqliteMetric, func(ctx context.Context, conn *sql.Conn) error {
		var err error
		materialized, err = s.materializeSettlementAttemptOutputForConn(ctx, conn, id)
		return err
	})
	if err != nil {
		if errors.Is(err, errSettlementAttemptOutputJournalPoison) {
			if markErr := s.markSettlementAttemptOutputJournalPoisoned(ctx, id, err); markErr != nil {
				return false, fmt.Errorf("%w; mark settlement attempt output journal poison: %v", err, markErr)
			}
		}
	}
	return materialized, err
}

// SettlementAttemptOutputEvidenceExists reports whether an attempt has either
// an authoritative journal event or its materialized projection. Callers use
// it to distinguish an idempotent materialization no-op from missing evidence.
func (s *Store) SettlementAttemptOutputEvidenceExists(ctx context.Context, id SettlementReceiptIdentity) (bool, error) {
	if s == nil {
		return false, fmt.Errorf("billing store is nil")
	}
	if err := id.validate(); err != nil {
		return false, err
	}
	var exists int
	err := s.reader().QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1 FROM settlement_attempt_output_journal
     WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?
    UNION ALL
    SELECT 1 FROM settlement_attempt_outputs
     WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?
)`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	).Scan(&exists)
	return exists == 1, err
}

func (s *Store) MaterializePendingSettlementAttemptOutputs(ctx context.Context, limit int) (SettlementAttemptOutputMaterializationResult, error) {
	if s == nil {
		return SettlementAttemptOutputMaterializationResult{}, fmt.Errorf("billing store is nil")
	}
	if limit <= 0 {
		limit = 100
	}
	rows, err := s.reader().QueryContext(ctx, `
SELECT account_scope, request_id, attempt_n, provider_id
  FROM settlement_attempt_output_journal INDEXED BY idx_saoj_pending
 WHERE materialized_at_utc IS NULL
   AND poisoned_at_utc IS NULL
 ORDER BY id
 LIMIT ?`, limit)
	if err != nil {
		return SettlementAttemptOutputMaterializationResult{}, err
	}
	var ids []SettlementReceiptIdentity
	for rows.Next() {
		var id SettlementReceiptIdentity
		if err := rows.Scan(&id.AccountScope, &id.RequestID, &id.AttemptN, &id.ProviderID); err != nil {
			_ = rows.Close()
			return SettlementAttemptOutputMaterializationResult{}, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return SettlementAttemptOutputMaterializationResult{}, err
	}
	if err := rows.Close(); err != nil {
		return SettlementAttemptOutputMaterializationResult{}, err
	}
	result := SettlementAttemptOutputMaterializationResult{SelectedRows: len(ids)}
	var firstErr error
	for _, id := range ids {
		materialized, err := s.MaterializeSettlementAttemptOutputFor(ctx, id)
		if err != nil {
			if errors.Is(err, errSettlementAttemptOutputJournalPoison) {
				result.PoisonedRows++
			}
			if firstErr == nil {
				firstErr = err
			}
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				break
			}
			continue
		}
		if materialized {
			result.MaterializedRows++
		} else {
			result.AlreadyMaterializedRows++
		}
	}
	return result, firstErr
}

func (s *Store) SettlementAttemptOutputJournalStats(ctx context.Context) (SettlementAttemptOutputJournalStats, error) {
	var stats SettlementAttemptOutputJournalStats
	if s == nil {
		return stats, fmt.Errorf("billing store is nil")
	}
	reader := s.reader()
	err := reader.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM settlement_attempt_output_journal
 WHERE materialized_at_utc IS NULL
   AND poisoned_at_utc IS NULL`).Scan(&stats.PendingRows)
	if err != nil {
		return stats, err
	}
	var oldest sql.NullString
	if err := reader.QueryRowContext(ctx, `
SELECT created_at_utc
  FROM settlement_attempt_output_journal INDEXED BY idx_saoj_pending_created
 WHERE materialized_at_utc IS NULL
   AND poisoned_at_utc IS NULL
 ORDER BY created_at_utc, id
 LIMIT 1`).Scan(&oldest); err != nil && err != sql.ErrNoRows {
		return stats, err
	}
	if err := reader.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM settlement_attempt_output_journal
 WHERE poisoned_at_utc IS NOT NULL
   AND poison_acknowledged_at_utc IS NULL`).Scan(&stats.PoisonedRows); err != nil {
		return stats, err
	}
	if err := reader.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM settlement_attempt_output_journal INDEXED BY idx_saoj_poisoned_all
 WHERE poisoned_at_utc IS NOT NULL`).Scan(&stats.RetainedPoisonedRows); err != nil {
		return stats, err
	}
	if oldest.Valid && oldest.String != "" {
		createdAt, err := time.Parse(time.RFC3339Nano, oldest.String)
		if err != nil {
			return stats, fmt.Errorf("parse settlement attempt output journal oldest pending created_at_utc: %w", err)
		}
		stats.OldestPendingCreatedAt = createdAt
		stats.HasOldestPendingCreated = true
		stats.OldestPendingAge = s.nowUTC().Sub(createdAt)
		if stats.OldestPendingAge < 0 {
			stats.OldestPendingAge = 0
		}
	}
	return stats, nil
}

// PruneSettlementAttemptOutputJournal removes only old rows whose projection
// is already durable. Pending and poisoned rows remain authoritative and are
// never selected by this bounded retention pass.
func (s *Store) PruneSettlementAttemptOutputJournal(ctx context.Context, cutoff time.Time, limit int) (int64, error) {
	if s == nil {
		return 0, fmt.Errorf("billing store is nil")
	}
	if limit <= 0 {
		return 0, nil
	}
	res, err := s.db.ExecContext(ctx, `
DELETE FROM settlement_attempt_output_journal
 WHERE id IN (
    SELECT id
     FROM settlement_attempt_output_journal INDEXED BY idx_saoj_materialized_retention
     WHERE materialized_at_utc IS NOT NULL
       AND poisoned_at_utc IS NULL
       AND materialized_at_utc < ?
     ORDER BY materialized_at_utc, id
     LIMIT ?
 )`, cutoff.UTC().Format(time.RFC3339Nano), limit)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *Store) materializeSettlementAttemptOutputForConn(ctx context.Context, conn *sql.Conn, id SettlementReceiptIdentity) (bool, error) {
	prepared, found, pending, err := loadSettlementAttemptOutputJournalConn(ctx, conn, id)
	if err != nil || !found || !pending {
		return false, err
	}
	now := s.nowUTC().Format(time.RFC3339Nano)
	if _, err := conn.ExecContext(ctx, `
UPDATE settlement_attempt_output_journal
   SET materialize_attempts = materialize_attempts + 1,
       last_materialize_attempt_at_utc = ?
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		now, id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	); err != nil {
		return false, err
	}
	inserted, err := insertSettlementAttemptOutputConn(ctx, conn, prepared, false, s.nowUTC())
	if err != nil {
		return false, err
	}
	res, err := conn.ExecContext(ctx, `
UPDATE settlement_attempt_output_journal
   SET materialized_at_utc = COALESCE(materialized_at_utc, ?),
       last_materialize_error = ''
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?
   AND materialized_at_utc IS NULL
   AND poisoned_at_utc IS NULL`,
		now, id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	)
	if err != nil {
		return false, err
	}
	if rows, err := res.RowsAffected(); err == nil && rows == 0 {
		return false, nil
	}
	return inserted, nil
}

func (s *Store) markSettlementAttemptOutputJournalPoisoned(ctx context.Context, id SettlementReceiptIdentity, cause error) error {
	if cause == nil {
		return nil
	}
	now := s.nowUTC().Format(time.RFC3339Nano)
	message := cause.Error()
	res, err := s.db.ExecContext(ctx, `
UPDATE settlement_attempt_output_journal
   SET materialize_attempts = materialize_attempts + 1,
       last_materialize_attempt_at_utc = COALESCE(last_materialize_attempt_at_utc, ?),
       last_materialize_error = ?,
       poisoned_at_utc = COALESCE(poisoned_at_utc, ?),
       poison_reason = CASE WHEN poison_reason = '' THEN ? ELSE poison_reason END
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		now, message, now, message,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return fmt.Errorf("settlement attempt output journal row not found for poison retention")
	}
	return nil
}

func loadSettlementAttemptOutputJournalConn(ctx context.Context, conn *sql.Conn, id SettlementReceiptIdentity) (preparedSettlementAttemptOutput, bool, bool, error) {
	var outputHash sql.NullString
	var materializedAt sql.NullString
	var poisonedAt sql.NullString
	var outputAvailable, overlap int
	var prepared preparedSettlementAttemptOutput
	attempt := SettlementAttemptOutput{
		AccountScope: id.AccountScope,
		RequestID:    id.RequestID,
		AttemptN:     id.AttemptN,
		ProviderID:   id.ProviderID,
	}
	err := conn.QueryRowContext(ctx, `
SELECT terminal_state, terminal_state_ts_unix_ms, output_available,
       output_prefix_start_byte, output_prefix_end_byte, output_hash,
       usage_hash, usage_canonical_json, usage_source,
       overlapping_or_duplicate, payload_hash,
       materialized_at_utc, poisoned_at_utc
  FROM settlement_attempt_output_journal
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	).Scan(
		&attempt.Output.TerminalState,
		&attempt.TerminalStateTSUnixMS,
		&outputAvailable,
		&attempt.Output.OutputPrefixStartByte,
		&attempt.Output.OutputPrefixEndByte,
		&outputHash,
		&prepared.usageHash,
		&prepared.usageCanonical,
		&attempt.UsageSource,
		&overlap,
		&prepared.payloadHash,
		&materializedAt,
		&poisonedAt,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return preparedSettlementAttemptOutput{}, false, false, nil
		}
		return preparedSettlementAttemptOutput{}, false, false, err
	}
	attempt.OutputAvailable = outputAvailable == 1
	attempt.OverlappingOrDuplicate = overlap == 1
	if outputHash.Valid {
		prepared.outputHash = outputHash.String
	}
	var usage settlementUsageV04
	if err := json.Unmarshal([]byte(prepared.usageCanonical), &usage); err != nil {
		return preparedSettlementAttemptOutput{}, true, false, fmt.Errorf("%w: decode usage: %v", errSettlementAttemptOutputJournalPoison, err)
	}
	attempt.Usage = SettlementUsage{
		BillableInputTokens:  usage.BillableInputTokens,
		BillableOutputTokens: usage.BillableOutputTokens,
		DeliveredOutputBytes: usage.DeliveredOutputBytes,
		ObservedInputTokens:  usage.ObservedInputTokens,
		ObservedOutputTokens: usage.ObservedOutputTokens,
	}
	attempt.Output.Content = ""
	attempt.Output.Available = attempt.OutputAvailable
	prepared.attempt = attempt
	pending := !materializedAt.Valid && !poisonedAt.Valid
	return prepared, true, pending, nil
}
