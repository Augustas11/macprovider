package payout

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/rs/zerolog"
)

// SPEC-016 §4.8b — singleton-runner lease.
//
// All lease operations use the raw *sql.Conn + raw BEGIN
// IMMEDIATE pattern (matching addresses.go and the §3.3
// TOCTOU re-check). The driver-default BEGIN DEFERRED would
// not take a write-intent lock at txn start, breaking the
// serialisation of acquire/takeover against concurrent
// readers.

// LeaseState captures the in-memory token + identifiers the
// lease holder process needs for self-fence checks and heartbeat
// re-assertions.
type LeaseState struct {
	HolderToken string
	HolderHost  string
	HolderPID   int
	StartedAt   time.Time
}

// ErrLeaseConflict is returned by Acquire when a fresh holder
// already owns the lease (heartbeat within window). Caller emits
// payout_runner_lease_conflict per §7.1 + refuses to start.
var ErrLeaseConflict = errors.New("payout: runner lease conflict (fresh holder)")

// ErrLeaseLost surfaces from Heartbeat / SelfFence when this
// process has been taken over. Caller emits
// payout_runner_lease_lost + self-halts.
var ErrLeaseLost = errors.New("payout: runner lease lost")

// ErrRunnerHalted is returned by RunOnce when RequestHalt has been
// called (typically by the §7.4 chain-balance worker on negative
// drift). Caller observes via errors.Is; admin /admin/payout/run-now
// returns 409 in this case. SPEC §7.4 + Step 4 r1 [arch:4.1]/
// [sec:r1-1] convergent closure.
var ErrRunnerHalted = errors.New("payout: runner halted (operator action required)")

// Acquire implements the §4.8b Acquire semantics:
//
//   - No row → INSERT (fresh acquire).
//   - Row exists + heartbeat ≥ now − (3 × runInterval) → ErrLeaseConflict.
//   - Row exists + heartbeat < now − (3 × runInterval) → TAKEOVER
//     (UPDATE, takeover_count++) + caller emits
//     payout_runner_lease_taken_over.
//
// Returns the LeaseState (including the fresh holder_token) on
// success.
func Acquire(ctx context.Context, db *sql.DB, runInterval time.Duration, log zerolog.Logger) (LeaseState, bool, error) {
	host, _ := os.Hostname()
	pid := os.Getpid()
	now := time.Now().UTC()
	token, err := freshLeaseToken()
	if err != nil {
		return LeaseState{}, false, fmt.Errorf("Acquire: token: %w", err)
	}
	state := LeaseState{
		HolderToken: token,
		HolderHost:  host,
		HolderPID:   pid,
		StartedAt:   now,
	}

	conn, err := db.Conn(ctx)
	if err != nil {
		return LeaseState{}, false, fmt.Errorf("Acquire: conn: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return LeaseState{}, false, fmt.Errorf("Acquire: BEGIN IMMEDIATE: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// Try to read the existing row.
	var (
		existingHost      string
		existingPID       int64
		existingStartedAt string
		existingToken     string
		existingHeartbeat string
		existingTakeover  int64
	)
	row := conn.QueryRowContext(ctx, `
SELECT holder_host, holder_pid, holder_started_at_utc, holder_token,
       heartbeat_at_utc, takeover_count
  FROM payout_runner_lease
 WHERE id = 1`)
	err = row.Scan(&existingHost, &existingPID, &existingStartedAt, &existingToken, &existingHeartbeat, &existingTakeover)
	if errors.Is(err, sql.ErrNoRows) {
		// Fresh acquire.
		if _, err := conn.ExecContext(ctx, `
INSERT INTO payout_runner_lease
  (id, holder_host, holder_pid, holder_started_at_utc, holder_token,
   heartbeat_at_utc, acquired_at_utc, takeover_count)
VALUES (1, ?, ?, ?, ?, ?, ?, 0)`,
			host, pid, formatUTC(now), token, formatUTC(now), formatUTC(now),
		); err != nil {
			return LeaseState{}, false, fmt.Errorf("Acquire: fresh INSERT: %w", err)
		}
		if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
			return LeaseState{}, false, fmt.Errorf("Acquire: fresh COMMIT: %w", err)
		}
		committed = true
		log.Info().Str("holder_token_prefix", token[:8]).Msg("payout runner lease acquired (fresh)")
		return state, false, nil
	}
	if err != nil {
		return LeaseState{}, false, fmt.Errorf("Acquire: SELECT existing: %w", err)
	}

	// Row exists — check heartbeat freshness.
	hbTime, err := time.Parse(time.RFC3339Nano, existingHeartbeat)
	if err != nil {
		// Belt-and-suspenders: try the lenient format.
		hbTime, err = time.Parse(time.RFC3339, existingHeartbeat)
		if err != nil {
			return LeaseState{}, false, fmt.Errorf("Acquire: parse heartbeat: %w", err)
		}
	}
	staleWindow := 3 * runInterval
	if now.Sub(hbTime) < staleWindow {
		// Fresh holder — conflict.
		return LeaseState{}, false, fmt.Errorf("%w: holder_host=%s holder_pid=%d holder_started_at_utc=%s heartbeat_at_utc=%s",
			ErrLeaseConflict, existingHost, existingPID, existingStartedAt, existingHeartbeat)
	}

	// Stale holder — TAKEOVER.
	if _, err := conn.ExecContext(ctx, `
UPDATE payout_runner_lease
   SET holder_host = ?, holder_pid = ?, holder_started_at_utc = ?,
       holder_token = ?, heartbeat_at_utc = ?, acquired_at_utc = ?,
       takeover_count = takeover_count + 1
 WHERE id = 1`,
		host, pid, formatUTC(now), token, formatUTC(now), formatUTC(now),
	); err != nil {
		return LeaseState{}, false, fmt.Errorf("Acquire: takeover UPDATE: %w", err)
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return LeaseState{}, false, fmt.Errorf("Acquire: takeover COMMIT: %w", err)
	}
	committed = true
	log.Warn().
		Str("event", "payout_runner_lease_taken_over").
		Str("severity", "PAGE").
		Str("prior_holder_host", existingHost).
		Int64("prior_holder_pid", existingPID).
		Str("prior_holder_started_at_utc", existingStartedAt).
		Str("prior_heartbeat_at_utc", existingHeartbeat).
		Str("new_holder_host", host).
		Int("new_holder_pid", pid).
		Int64("takeover_count", existingTakeover+1).
		Str("ts_utc", formatUTC(now)).
		Msg("payout runner lease taken over from stale holder")
	return state, true, nil
}

// Heartbeat re-stamps heartbeat_at_utc inside a BEGIN IMMEDIATE
// txn, re-asserting WHERE holder_token = ours. On 0 rows affected
// the caller has been taken over — returns ErrLeaseLost.
func Heartbeat(ctx context.Context, db *sql.DB, state LeaseState, log zerolog.Logger) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("Heartbeat: conn: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return fmt.Errorf("Heartbeat: BEGIN IMMEDIATE: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	now := time.Now().UTC()
	res, err := conn.ExecContext(ctx, `
UPDATE payout_runner_lease
   SET heartbeat_at_utc = ?
 WHERE id = 1 AND holder_token = ?`, formatUTC(now), state.HolderToken)
	if err != nil {
		return fmt.Errorf("Heartbeat: UPDATE: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		// Read the current row to enrich the lease_lost event.
		var observedToken, observedHost string
		var observedPID int64
		_ = conn.QueryRowContext(ctx,
			`SELECT holder_token, holder_host, holder_pid FROM payout_runner_lease WHERE id = 1`,
		).Scan(&observedToken, &observedHost, &observedPID)
		// Codex Step 3 r1 [sec:3] MEDIUM closure: lease tokens
		// are runtime secrets used for self-fencing; emit only
		// the 8-char prefix (mirrors main.go's stale-out warn).
		log.Error().
			Str("event", "payout_runner_lease_lost").
			Str("severity", "PAGE").
			Int("local_pid", state.HolderPID).
			Str("local_holder_token_prefix", tokenPrefix(state.HolderToken)).
			Str("observed_holder_token_prefix", tokenPrefix(observedToken)).
			Str("observed_holder_host", observedHost).
			Int64("observed_holder_pid", observedPID).
			Str("ts_utc", formatUTC(now)).
			Msg("payout runner lease lost")
		return ErrLeaseLost
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return fmt.Errorf("Heartbeat: COMMIT: %w", err)
	}
	committed = true
	return nil
}

// SelfFenceTx re-reads the holder_token INSIDE an already-open
// BEGIN IMMEDIATE transaction and returns ErrLeaseLost on
// mismatch. Used by §4.3 step 6 CAS-persist before the
// raw_signed_tx UPDATE.
func SelfFenceTx(ctx context.Context, conn *sql.Conn, state LeaseState) error {
	var observed string
	err := conn.QueryRowContext(ctx,
		`SELECT holder_token FROM payout_runner_lease WHERE id = 1`,
	).Scan(&observed)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%w: lease row missing", ErrLeaseLost)
	}
	if err != nil {
		return fmt.Errorf("SelfFenceTx: SELECT: %w", err)
	}
	if observed != state.HolderToken {
		return ErrLeaseLost
	}
	return nil
}

// SelfFence is the standalone (no-txn) self-fence read for §4.3
// step 6 post-COMMIT + steps 7/8.
func SelfFence(ctx context.Context, db *sql.DB, state LeaseState) error {
	var observed string
	err := db.QueryRowContext(ctx,
		`SELECT holder_token FROM payout_runner_lease WHERE id = 1`,
	).Scan(&observed)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%w: lease row missing", ErrLeaseLost)
	}
	if err != nil {
		return fmt.Errorf("SelfFence: SELECT: %w", err)
	}
	if observed != state.HolderToken {
		return ErrLeaseLost
	}
	return nil
}

// Release deletes the lease row on clean shutdown so the next
// process can acquire without waiting the stale window.
func Release(ctx context.Context, db *sql.DB, state LeaseState, log zerolog.Logger) error {
	_, err := db.ExecContext(ctx,
		`DELETE FROM payout_runner_lease WHERE id = 1 AND holder_token = ?`,
		state.HolderToken,
	)
	if err != nil {
		log.Warn().Err(err).Msg("payout runner lease release failed")
	}
	return err
}

// IsLeaseActive reports whether the lease row has a heartbeat
// inside the staleness window — used by §4.6 abandon endpoint's
// runner-active gate.
func IsLeaseActive(ctx context.Context, conn *sql.Conn, runInterval time.Duration) (bool, error) {
	var hb string
	err := conn.QueryRowContext(ctx, `SELECT heartbeat_at_utc FROM payout_runner_lease WHERE id = 1`).Scan(&hb)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	hbTime, err := time.Parse(time.RFC3339Nano, hb)
	if err != nil {
		hbTime, err = time.Parse(time.RFC3339, hb)
		if err != nil {
			return false, fmt.Errorf("parse heartbeat: %w", err)
		}
	}
	return time.Since(hbTime) < 3*runInterval, nil
}

// ---- helpers ------------------------------------------------------------

func freshLeaseToken() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}

func formatUTC(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

// tokenPrefix returns the first 8 characters of a holder_token
// for logging purposes (codex Step 3 r1 [sec:3] MEDIUM closure).
// Tokens shorter than 8 chars are returned verbatim; a malformed
// short token leaks no more information than its length.
func tokenPrefix(s string) string {
	if len(s) <= 8 {
		return s
	}
	return s[:8]
}

// canonicalAddressForCompare lowers an address; lease.go does not
// own EIP-55 — addresses.go is canonical for that. This is just
// a defensive normalisation if the lease ever wants to compare
// host names case-insensitively (currently not used; defensive
// hook for the audit lane).
func canonicalAddressForCompare(s string) string { return strings.ToLower(s) }

var _ = canonicalAddressForCompare // keep symbol live for forward use
