package payout

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/rs/zerolog"
)

// closedSetFlags enumerates the SPEC-016 §4.8a closed-set
// runtime flags. v0.1.x contains exactly one. Sentinel-asymmetry
// detection walks this list to catch the
// "sentinel-row-deleted but flag-row-present" tamper signal AND
// the inverse "sentinel-present but flag-row-missing" case.
var closedSetFlags = []string{
	"registration_paused",
}

// InvariantViolation captures a SPEC §4.8a "halt before
// accepting traffic" event. main.go converts it to a structured
// zerolog emit + os.Exit before the listeners come up.
type InvariantViolation struct {
	Where   string
	Name    string
	Message string
}

func (v InvariantViolation) Error() string {
	if v.Name == "" {
		return fmt.Sprintf("payout_invariant_violation where=%q: %s", v.Where, v.Message)
	}
	return fmt.Sprintf("payout_invariant_violation where=%q name=%q: %s", v.Where, v.Name, v.Message)
}

// InitRunnerStateRow inserts the single payout_runner_state row
// if it does not exist. SPEC §4.8 NORMATIVE: this MUST run in
// main.go BEFORE runner.Start() so the bootstrap-flip trigger
// has a row to UPDATE on the first confirmed attempt. Idempotent
// across restarts.
func InitRunnerStateRow(ctx context.Context, db *sql.DB, now time.Time) error {
	if db == nil {
		return fmt.Errorf("payout.InitRunnerStateRow: db is required")
	}
	_, err := db.ExecContext(ctx,
		`INSERT OR IGNORE INTO payout_runner_state (id, payout_bootstrap_complete, updated_at_utc) VALUES (1, 0, ?)`,
		now.UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		return fmt.Errorf("payout.InitRunnerStateRow: %w", err)
	}
	return nil
}

// BootstrapRuntimeFlags runs the SPEC §4.8a first-ever-init seed
// or refuses to seed depending on the three-table state. Action
// table (SPEC L2319-L2336):
//
//   - bootstrapped EMPTY, flags EMPTY, audit EMPTY → seed.
//   - bootstrapped NONEMPTY, flags NONEMPTY → normal restart;
//     skip seed; let runtime callers honor the existing rows.
//   - bootstrapped NONEMPTY, flags EMPTY for ANY closed-set flag
//     → invariant violation; HALT.
//   - bootstrapped EMPTY, flags NONEMPTY OR audit NONEMPTY →
//     invariant violation; HALT.
//
// On the seed path the function INSERTs every closedSetFlags
// row at value=0 with actor "system:bootstrap_seed" AND the
// sentinel row, all in one BEGIN IMMEDIATE txn.
//
// Callers MUST treat any returned error as terminal (do not
// silently recover) — every failure mode here is either a
// tamper signal or a transient DB error that warrants restart
// rather than continuing with a partial seed.
func BootstrapRuntimeFlags(ctx context.Context, db *sql.DB, now time.Time, log zerolog.Logger) error {
	if db == nil {
		return fmt.Errorf("payout.BootstrapRuntimeFlags: db is required")
	}

	bootstrappedCount, err := scanCount(ctx, db, `SELECT count(*) FROM runtime_flags_bootstrapped`)
	if err != nil {
		return fmt.Errorf("read runtime_flags_bootstrapped: %w", err)
	}
	flagsCount, err := scanCount(ctx, db, `SELECT count(*) FROM runtime_flags`)
	if err != nil {
		return fmt.Errorf("read runtime_flags: %w", err)
	}
	auditCount, err := scanCount(ctx, db, `SELECT count(*) FROM runtime_flag_audit`)
	if err != nil {
		return fmt.Errorf("read runtime_flag_audit: %w", err)
	}

	if bootstrappedCount == 0 && flagsCount == 0 && auditCount == 0 {
		// First-ever boot — seed.
		return seedRuntimeFlags(ctx, db, now)
	}

	if bootstrappedCount == 0 && (flagsCount > 0 || auditCount > 0) {
		// Sentinel deleted / partial restore — REFUSE to reseed.
		violation := InvariantViolation{
			Where:   "runtime_flags_bootstrap_sentinel_missing",
			Message: "sentinel row absent but runtime_flags/audit rows present — tamper signal or partial restore",
		}
		emitInvariantViolation(log, violation)
		return violation
	}

	if bootstrappedCount > 0 {
		// Normal restart — verify every closed-set flag still
		// has its row. A missing closed-set row at non-first
		// boot is the "tamper" branch SPEC §4.8a normatively
		// halts on.
		for _, name := range closedSetFlags {
			ok, err := flagExists(ctx, db, name)
			if err != nil {
				return fmt.Errorf("check flag %q: %w", name, err)
			}
			if !ok {
				violation := InvariantViolation{
					Where:   "runtime_flag missing",
					Name:    name,
					Message: "closed-set runtime flag row absent at non-first-boot",
				}
				emitInvariantViolation(log, violation)
				return violation
			}
		}
	}

	return nil
}

func seedRuntimeFlags(ctx context.Context, db *sql.DB, now time.Time) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return fmt.Errorf("begin immediate: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	stamp := now.UTC().Format(time.RFC3339Nano)
	for _, name := range closedSetFlags {
		if _, err := conn.ExecContext(ctx,
			`INSERT INTO runtime_flags (name, value, updated_at_utc, updated_by_actor, updated_reason) VALUES (?, 0, ?, 'system:bootstrap_seed', '')`,
			name, stamp,
		); err != nil {
			return fmt.Errorf("seed runtime_flags %q: %w", name, err)
		}
	}
	if _, err := conn.ExecContext(ctx,
		`INSERT INTO runtime_flags_bootstrapped (id, bootstrapped_at_utc) VALUES (1, ?)`,
		stamp,
	); err != nil {
		return fmt.Errorf("seed runtime_flags_bootstrapped: %w", err)
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return fmt.Errorf("commit seed: %w", err)
	}
	committed = true
	return nil
}

func flagExists(ctx context.Context, db *sql.DB, name string) (bool, error) {
	var got string
	err := db.QueryRowContext(ctx,
		`SELECT name FROM runtime_flags WHERE name=?`, name,
	).Scan(&got)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return got == name, nil
}

func scanCount(ctx context.Context, db *sql.DB, query string) (int64, error) {
	var n int64
	if err := db.QueryRowContext(ctx, query).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

func emitInvariantViolation(log zerolog.Logger, v InvariantViolation) {
	log.Error().
		Str("event", "payout_invariant_violation").
		Str("where", v.Where).
		Str("name", v.Name).
		Str("severity", "PAGE").
		Msg(v.Message)
}
