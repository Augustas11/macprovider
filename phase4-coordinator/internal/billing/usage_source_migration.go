package billing

import (
	"context"
	"fmt"
	"strings"
)

// SPEC-022-R012.6a migration: widen the settlement_attempt_outputs.usage_source
// CHECK to the R-12.2 vocabulary without rewriting any existing row.
const (
	usageSourceCheckV01 = "CHECK(usage_source IN ('coordinator_observed','byte_estimated'))"
	usageSourceCheckV02 = "CHECK(usage_source IN ('coordinator_observed','byte_estimated','pool_operator_attested'))"
)

// ensureSettlementAttemptOutputUsageSourceVocabulary edits only the stored
// table definition (the SQLite writable_schema procedure for a constraint
// change that does not alter the on-disk row format). Every existing value
// already satisfies the wider CHECK, no row is read or written, and the
// schema cookie is bumped so every open connection reloads the definition.
// A database created at this version already carries the wide CHECK.
func (s *Store) ensureSettlementAttemptOutputUsageSourceVocabulary(ctx context.Context) error {
	var definition string
	if err := s.db.QueryRowContext(ctx, `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'settlement_attempt_outputs'`).Scan(&definition); err != nil {
		return err
	}
	if strings.Contains(definition, usageSourceCheckV02) {
		return nil
	}
	if strings.Count(definition, usageSourceCheckV01) != 1 {
		return fmt.Errorf("settlement_attempt_outputs usage_source CHECK has an unexpected definition")
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
	res, err := conn.ExecContext(ctx, `UPDATE sqlite_master SET sql = replace(sql, ?, ?) WHERE type = 'table' AND name = 'settlement_attempt_outputs'`, usageSourceCheckV01, usageSourceCheckV02)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n != 1 {
		return fmt.Errorf("settlement_attempt_outputs usage_source CHECK migration updated %d definitions: %v", n, err)
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
	var check string
	if err := conn.QueryRowContext(ctx, `PRAGMA quick_check`).Scan(&check); err != nil {
		return err
	}
	if check != "ok" {
		return fmt.Errorf("settlement_attempt_outputs usage_source CHECK migration: quick_check %q", check)
	}
	return nil
}
