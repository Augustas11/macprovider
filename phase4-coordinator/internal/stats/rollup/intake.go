package rollup

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/intake"
)

// fleetRAMClassFloors is the fixed closed class list of SPEC-017 v0.2.1
// §5.2b.6, in emission order.
var fleetRAMClassFloors = []int{8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 512}

// fleetRAMPeriod is the SPEC-017 §5.2b.6 materialization period: the
// histogram is computed at most once per period and held byte-identical
// until the next period boundary, so successive polls never differ by one
// provider's arrival or departure.
const fleetRAMPeriod = 30 * 24 * time.Hour

// FleetRAMClass is one `fleet_ram.classes` element.
type FleetRAMClass struct {
	RAMGBFloor    int  `json:"ram_gb_floor"`
	ProviderCount *int `json:"provider_count"`
	Suppressed    bool `json:"suppressed"`
}

// FleetRAM is the `fleet_ram` object of `macprovider.stats-intake.v1`.
type FleetRAM struct {
	WindowStart        string          `json:"window_start"`
	WindowEnd          string          `json:"window_end"`
	KAnonymityMin      int             `json:"k_anonymity_min"`
	ProviderTotal      int             `json:"provider_total"`
	ProviderSuppressed int             `json:"provider_suppressed"`
	Classes            []FleetRAMClass `json:"classes"`
}

// BuildFleetRAM buckets active providers' verified unified memory by class
// floor and applies complementary suppression (SPEC-017 §5.2b.6): a class
// below k is suppressed, and when any class is suppressed the smallest
// unsuppressed class is suppressed too (ties: the HIGHEST floor, the more
// identifying end of the fleet), so the residual never isolates one small
// class. A provider below the lowest floor belongs to no class and is
// folded into provider_suppressed, so provider_total always equals the
// emitted counts plus provider_suppressed. memoryGB holds one value per
// active provider.
func BuildFleetRAM(memoryGB []int, windowStart, windowEnd time.Time, k int) FleetRAM {
	counts := make([]int, len(fleetRAMClassFloors))
	subFloor := 0
	for _, gb := range memoryGB {
		class := -1
		for i, floor := range fleetRAMClassFloors {
			if gb >= floor {
				class = i
			}
		}
		if class >= 0 {
			counts[class]++
		} else {
			subFloor++
		}
	}
	suppressed := make([]bool, len(fleetRAMClassFloors))
	anySuppressed := false
	for i, n := range counts {
		if n < k {
			suppressed[i] = true
			anySuppressed = true
		}
	}
	if anySuppressed {
		// Complementary suppression: also hide the smallest emitted class;
		// on a tie prefer the highest floor.
		smallest := -1
		for i, n := range counts {
			if suppressed[i] {
				continue
			}
			if smallest < 0 || n <= counts[smallest] {
				smallest = i
			}
		}
		if smallest >= 0 {
			suppressed[smallest] = true
		}
	}
	out := FleetRAM{
		WindowStart:        windowStart.UTC().Format(time.RFC3339),
		WindowEnd:          windowEnd.UTC().Format(time.RFC3339),
		KAnonymityMin:      k,
		ProviderTotal:      len(memoryGB),
		ProviderSuppressed: subFloor,
		Classes:            make([]FleetRAMClass, 0, len(fleetRAMClassFloors)),
	}
	for i, floor := range fleetRAMClassFloors {
		if suppressed[i] {
			out.ProviderSuppressed += counts[i]
			out.Classes = append(out.Classes, FleetRAMClass{RAMGBFloor: floor, Suppressed: true})
			continue
		}
		count := counts[i]
		out.Classes = append(out.Classes, FleetRAMClass{RAMGBFloor: floor, ProviderCount: &count})
	}
	return out
}

// fleetRAMPeriodIndex identifies the materialization period a time falls
// in: fixed 30-day periods counted from the Unix epoch, in UTC.
func fleetRAMPeriodIndex(t time.Time) int64 {
	return t.UTC().Unix() / int64(fleetRAMPeriod/time.Second)
}

// fleetRAMCurrent reports whether a persisted histogram passes the closed
// contract (intake.ValidateFleetRAMJSON) AND was materialized in the same
// period as now; if so its bytes are kept verbatim for the rest of the
// period. A malformed, foreign-period, or future histogram is recomputed.
func fleetRAMCurrent(raw []byte, now time.Time) bool {
	if err := intake.ValidateFleetRAMJSON(raw); err != nil {
		return false
	}
	var f struct {
		WindowEnd string `json:"window_end"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		return false
	}
	end, err := intake.ParseUTC(f.WindowEnd)
	if err != nil || end.After(now) {
		return false
	}
	return fleetRAMPeriodIndex(end) == fleetRAMPeriodIndex(now)
}

// ErrIntakeWindowConflict reports one window_id carrying two byte
// representations; the tick fails closed (SPEC-017 §5.2b.5).
var ErrIntakeWindowConflict = errors.New("intake: one window_id carries two different windows")

// ErrIntakeWindowInvalid reports a persisted or aggregator window that
// fails the closed wire contract; the tick fails closed rather than serve
// or re-persist it (SPEC-017 §5.2b.5).
var ErrIntakeWindowInvalid = errors.New("intake: window fails the wire contract")

// MergeIntakeWindows merges the aggregator's complete windows into the
// persisted set by window_id (SPEC-017 §5.2b.5). Every window on either
// side is validated against the closed wire contract (intake.ValidateWindow)
// and an invalid one fails the merge; an id appearing twice on one side or
// on both sides must carry identical bytes (else ErrIntakeWindowConflict).
// The result is ordered by descending window_start (ties by id), at most
// intake.MaxEmittedWindows, none whose end is older than
// intake.EmissionRetention before now.
func MergeIntakeWindows(current []intake.Window, persisted []intake.Window, now time.Time) ([]intake.Window, error) {
	byID := make(map[string]intake.Window, len(current)+len(persisted))
	add := func(w intake.Window) error {
		if err := intake.ValidateWindow(w); err != nil {
			return fmt.Errorf("%w: %v", ErrIntakeWindowInvalid, err)
		}
		if existing, ok := byID[w.WindowID]; ok {
			a, _ := json.Marshal(existing)
			b, _ := json.Marshal(w)
			if !bytes.Equal(a, b) {
				return fmt.Errorf("%w: %s", ErrIntakeWindowConflict, w.WindowID)
			}
			return nil
		}
		byID[w.WindowID] = w
		return nil
	}
	for _, w := range persisted {
		if err := add(w); err != nil {
			return nil, err
		}
	}
	for _, w := range current {
		if err := add(w); err != nil {
			return nil, err
		}
	}
	cutoff := now.Add(-intake.EmissionRetention)
	windows := make([]intake.Window, 0, len(byID))
	for _, w := range byID {
		end, _ := intake.ParseUTC(*w.WindowEnd) // validated above
		if end.Before(cutoff) {
			continue
		}
		windows = append(windows, w)
	}
	sort.Slice(windows, func(i, j int) bool {
		if windows[i].WindowStart != windows[j].WindowStart {
			return windows[i].WindowStart > windows[j].WindowStart
		}
		return windows[i].WindowID < windows[j].WindowID
	})
	if len(windows) > intake.MaxEmittedWindows {
		windows = windows[:intake.MaxEmittedWindows]
	}
	return windows, nil
}

// runIntakeTick writes the singleton stats_intake_current row.
func runIntakeTick(ctx context.Context, db *sql.DB, snap SnapshotProvider, now time.Time) error {
	now = now.UTC()
	current := intake.UnmatchedModels{Contract: intake.Contract, Windows: []intake.Window{}}
	if ip, ok := snap.(IntakeSnapshotProvider); ok {
		current = ip.IntakeSnapshot()
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("intake begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	// Merge with the persisted complete windows so a restart never loses
	// one that was already recorded (SPEC-017 §5.2b.5); reuse the
	// persisted fleet histogram while its materialization period lasts
	// (§5.2b.6).
	var persisted intake.UnmatchedModels
	var persistedFleet []byte
	{
		var raw []byte
		err := tx.QueryRowContext(ctx, `SELECT unmatched_models, fleet_ram FROM stats_intake_current WHERE singleton = TRUE`).Scan(&raw, &persistedFleet)
		switch {
		case err == sql.ErrNoRows:
		case err != nil:
			return fmt.Errorf("intake read previous: %w", err)
		default:
			if uerr := json.Unmarshal(raw, &persisted); uerr != nil {
				return fmt.Errorf("intake decode previous: %w", uerr)
			}
		}
	}
	merged, err := MergeIntakeWindows(current.Windows, persisted.Windows, now)
	if err != nil {
		return err
	}
	current.Contract = intake.Contract
	current.Windows = merged

	fleetJSON := persistedFleet
	if !fleetRAMCurrent(persistedFleet, now) {
		windowStart := now.Add(-fleetRAMPeriod)
		memoryGB, err := activeProviderMemory(ctx, tx, windowStart, now)
		if err != nil {
			return err
		}
		fleet := BuildFleetRAM(memoryGB, windowStart, now, intake.KAnonymityMin)
		fleetJSON, err = json.Marshal(fleet)
		if err != nil {
			return fmt.Errorf("intake fleet marshal: %w", err)
		}
	}

	unmatchedJSON, err := json.Marshal(current)
	if err != nil {
		return fmt.Errorf("intake unmatched marshal: %w", err)
	}
	const upsert = `
        INSERT INTO stats_intake_current (singleton, generated_at, unmatched_models, fleet_ram)
        VALUES (TRUE, $1, $2::jsonb, $3::jsonb)
        ON CONFLICT (singleton) DO UPDATE SET
            generated_at = EXCLUDED.generated_at,
            unmatched_models = EXCLUDED.unmatched_models,
            fleet_ram = EXCLUDED.fleet_ram
    `
	if _, err := tx.ExecContext(ctx, upsert, now, string(unmatchedJSON), string(fleetJSON)); err != nil {
		return fmt.Errorf("intake upsert: %w", err)
	}
	if err := healthOK(ctx, tx, componentIntake, now); err != nil {
		return fmt.Errorf("intake health: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("intake commit: %w", err)
	}
	committed = true
	return nil
}

// activeProviderMemory lists the verified unified memory of every provider
// active in the window (SPEC-017 §5.2b.6): a verified hardware profile
// whose last_reported_at lies in [windowStart, windowEnd] AND whose
// provider holds a hardware trust root active at windowEnd — a provider
// that was never trusted, or whose trust has expired, is not fleet. Only
// memory values are read; no identity column leaves the query.
func activeProviderMemory(ctx context.Context, tx *sql.Tx, windowStart, windowEnd time.Time) ([]int, error) {
	rows, err := tx.QueryContext(ctx, `
        SELECT ph.unified_memory_gb
          FROM provider_hardware_profiles ph
         WHERE ph.provider_id <> ''
           AND ph.verified = TRUE
           AND ph.last_reported_at >= $1
           AND ph.last_reported_at <= $2
           AND EXISTS (
                 SELECT 1
                   FROM hardware_verification_trust t
                  WHERE t.provider_id = ph.provider_id
                    AND (t.expires_at IS NULL OR t.expires_at > $2)
               )
    `, windowStart, windowEnd)
	if err != nil {
		return nil, fmt.Errorf("intake fleet query: %w", err)
	}
	defer rows.Close()
	out := []int{}
	for rows.Next() {
		var gb int
		if err := rows.Scan(&gb); err != nil {
			return nil, fmt.Errorf("intake fleet scan: %w", err)
		}
		out = append(out, gb)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("intake fleet rows: %w", err)
	}
	return out, nil
}
