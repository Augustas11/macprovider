package billing

import (
	"context"
	"fmt"
	"strings"
)

// SPEC-022 v0.3.0 (R-7.9, R-13.8) migration: widen the settlement verdict and
// audit-outbox CHECK constraints to admit relay_blind_settled and the
// relay-blind-settlement-v1 profile. Like the R-12.6a usage-source widening,
// it edits only the stored table definitions: every existing value already
// satisfies the wider CHECK, no row is read or rewritten, and a 4.8 GB money
// database is not copied before the coordinator listens.
const (
	settlementOutcomeCheckV1 = "CHECK(settlement_outcome IN ('pending','verified','quarantined','zero_settled'))"
	settlementOutcomeCheckV2 = "CHECK(settlement_outcome IN ('pending','verified','quarantined','zero_settled','relay_blind_settled'))"
	receiptProfileCheckV1    = "CHECK(receipt_profile = 'spec015-v0.4')"
	receiptProfileCheckV2    = "CHECK(receipt_profile IN ('spec015-v0.4','relay-blind-settlement-v1'))"
)

type schemaCheckWidening struct {
	table    string
	from, to string
}

var relayBlindSettlementOutcomeWidenings = []schemaCheckWidening{
	{table: "settlement_receipt_verdicts", from: settlementOutcomeCheckV1, to: settlementOutcomeCheckV2},
	{table: "settlement_receipt_verdicts", from: receiptProfileCheckV1, to: receiptProfileCheckV2},
	{table: "settlement_receipt_audit_outbox", from: settlementOutcomeCheckV1, to: settlementOutcomeCheckV2},
}

func (s *Store) ensureRelayBlindSettlementOutcomeVocabulary(ctx context.Context) error {
	if err := s.requireBillingCompatFloor(ctx); err != nil {
		return err
	}
	if err := s.widenSchemaChecks(ctx, relayBlindSettlementOutcomeWidenings); err != nil {
		return err
	}
	return s.recordBillingCompatFloor(ctx)
}

// widenSchemaChecks applies every pending CHECK replacement in one
// writable_schema transaction, bumps the schema cookie so open connections
// re-read the definitions, and then proves each edited table still parses.
func (s *Store) widenSchemaChecks(ctx context.Context, widenings []schemaCheckWidening) error {
	var pending []schemaCheckWidening
	for _, w := range widenings {
		var definition string
		if err := s.db.QueryRowContext(ctx, `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?`, w.table).Scan(&definition); err != nil {
			return err
		}
		if strings.Contains(definition, w.to) && !strings.Contains(definition, w.from) {
			continue
		}
		if strings.Count(definition, w.from) != 1 {
			return fmt.Errorf("%s CHECK has an unexpected definition for widening", w.table)
		}
		pending = append(pending, w)
	}
	if len(pending) == 0 {
		return nil
	}
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `PRAGMA writable_schema = OFF`)
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	var schemaVersion int64
	if err := conn.QueryRowContext(ctx, `PRAGMA schema_version`).Scan(&schemaVersion); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `PRAGMA writable_schema = ON`); err != nil {
		return err
	}
	for _, w := range pending {
		res, err := conn.ExecContext(ctx, `UPDATE sqlite_master SET sql = replace(sql, ?, ?) WHERE type = 'table' AND name = ?`, w.from, w.to, w.table)
		if err != nil {
			return err
		}
		if n, err := res.RowsAffected(); err != nil || n != 1 {
			return fmt.Errorf("%s CHECK widening updated %d definitions: %v", w.table, n, err)
		}
	}
	if _, err := conn.ExecContext(ctx, fmt.Sprintf(`PRAGMA schema_version = %d`, schemaVersion+1)); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `PRAGMA writable_schema = OFF`); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	for _, w := range pending {
		var edited string
		if err := conn.QueryRowContext(ctx, `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?`, w.table).Scan(&edited); err != nil {
			return err
		}
		if strings.Contains(edited, w.from) || !strings.Contains(edited, w.to) {
			return fmt.Errorf("%s CHECK widening left an unexpected definition", w.table)
		}
		rows, err := conn.QueryContext(ctx, `SELECT * FROM `+w.table+` LIMIT 0`)
		if err != nil {
			return fmt.Errorf("%s CHECK widening: edited schema does not parse: %w", w.table, err)
		}
		if err := rows.Close(); err != nil {
			return err
		}
	}
	return nil
}
