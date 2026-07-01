package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"
)

const (
	TerminalStateNormalDone                  = "normal_done"
	TerminalStateProviderError               = "provider_error"
	TerminalStateBuyerCancel                 = "buyer_cancel"
	TerminalStateGatewayTimeout              = "gateway_timeout"
	TerminalStateUpstreamTransportDisconnect = "upstream_transport_disconnect"

	UsageSourceCoordinatorObserved = "coordinator_observed"
	UsageSourceByteEstimated       = "byte_estimated"
)

var terminalStatePattern = regexp.MustCompile(`^(normal_done|provider_error|buyer_cancel|gateway_timeout|upstream_transport_disconnect)$`)

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
	case UsageSourceCoordinatorObserved, UsageSourceByteEstimated:
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

func (s *Store) InsertSettlementAttemptOutput(ctx context.Context, attempt SettlementAttemptOutput) (string, error) {
	if err := attempt.Validate(); err != nil {
		return "", err
	}
	outputHash := ""
	var err error
	if attempt.OutputAvailable {
		outputHash, _, err = attempt.Output.Digest()
		if err != nil {
			return "", err
		}
	}
	usageHash, usageCanonical, err := attempt.Usage.Digest()
	if err != nil {
		return "", err
	}
	now := time.Now().UTC()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()
	var overlapCount int
	if attempt.OutputAvailable {
		if err := tx.QueryRowContext(ctx, `
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
			attempt.Output.OutputPrefixStartByte, attempt.Output.OutputPrefixEndByte, outputHash,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
		).Scan(&overlapCount); err != nil {
			return "", err
		}
	}
	overlap := attempt.OverlappingOrDuplicate || overlapCount > 0
	res, err := tx.ExecContext(ctx, `
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
		nullableOutputString(outputHash, attempt.OutputAvailable),
		nil,
		usageHash,
		string(usageCanonical),
		attempt.UsageSource,
		boolInt(overlap),
		now.Format(time.RFC3339Nano),
	)
	if err != nil {
		return "", err
	}
	if overlap {
		if _, err := tx.ExecContext(ctx, `
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
			attempt.Output.OutputPrefixStartByte, attempt.Output.OutputPrefixEndByte, outputHash,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
			attempt.AttemptN, attempt.Output.OutputPrefixStartByte,
		); err != nil {
			return "", err
		}
	}
	if rows, err := res.RowsAffected(); err == nil && rows == 0 {
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
		err := tx.QueryRowContext(ctx, `
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
				return "", fmt.Errorf("settlement attempt output immutable conflict")
			}
			return "", err
		}
		if existing.TerminalState != attempt.Output.TerminalState ||
			existing.TerminalStateTSUnixMS != attempt.TerminalStateTSUnixMS ||
			existing.OutputAvailable != boolInt(attempt.OutputAvailable) ||
			existing.Start != attempt.Output.OutputPrefixStartByte ||
			existing.End != attempt.Output.OutputPrefixEndByte ||
			existing.OutputHash.Valid != attempt.OutputAvailable ||
			existing.OutputHash.String != outputHash ||
			existing.UsageHash != usageHash ||
			existing.UsageCanonical != string(usageCanonical) ||
			existing.UsageSource != attempt.UsageSource ||
			existing.Overlap != boolInt(overlap) {
			return "", fmt.Errorf("settlement attempt output immutable conflict")
		}
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	committed = true
	return outputHash, nil
}
