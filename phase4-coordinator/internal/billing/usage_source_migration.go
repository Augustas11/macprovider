package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
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
	if err := s.requireBillingCompatFloor(ctx); err != nil {
		return err
	}
	if err := s.widenSettlementAttemptOutputUsageSourceCheck(ctx); err != nil {
		return err
	}
	return s.recordBillingCompatFloor(ctx)
}

// billingCompatContract is the billing read contract this binary implements.
// 2 = SPEC-022 v0.2.0: settlement_attempt_outputs may hold
// pool_operator_attested rows that only a v0.2.0-aware verifier, finality,
// and report path may read. A coordinator refuses to open a database whose
// recorded floor is above its own contract, so a later rollback onto a binary
// that cannot read the newer rows fails closed at startup. Binaries that
// predate this floor cannot read it; SPEC-022-R012 (R-12.8) gates a
// downgrade to them with `coordinator pool-rollback-preflight`.
const billingCompatContract = 2

// ErrBillingCompatFloor means the database was written under a newer billing
// contract than this binary implements.
var ErrBillingCompatFloor = errors.New("billing: database requires a newer coordinator billing contract")

func (s *Store) requireBillingCompatFloor(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS billing_compat_floor (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    contract INTEGER NOT NULL CHECK(contract > 0),
    recorded_at_utc TEXT NOT NULL
)`); err != nil {
		return err
	}
	var floor int64
	err := s.db.QueryRowContext(ctx, `SELECT contract FROM billing_compat_floor WHERE id = 1`).Scan(&floor)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if floor > billingCompatContract {
		return fmt.Errorf("%w: floor %d > contract %d; roll forward instead", ErrBillingCompatFloor, floor, billingCompatContract)
	}
	return nil
}

func (s *Store) recordBillingCompatFloor(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO billing_compat_floor (id, contract, recorded_at_utc) VALUES (1, ?, ?)
ON CONFLICT(id) DO UPDATE SET contract = excluded.contract, recorded_at_utc = excluded.recorded_at_utc
 WHERE excluded.contract > billing_compat_floor.contract`,
		billingCompatContract, time.Now().UTC().Format(time.RFC3339Nano))
	return err
}

func (s *Store) widenSettlementAttemptOutputUsageSourceCheck(ctx context.Context) error {
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
