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
// unsuppressed class (ties: lowest floor) is suppressed too, so the
// residual never isolates one small class. memoryGB holds one value per
// active provider; a provider below the lowest floor counts in
// provider_total only.
func BuildFleetRAM(memoryGB []int, windowStart, windowEnd time.Time, k int) FleetRAM {
	counts := make([]int, len(fleetRAMClassFloors))
	for _, gb := range memoryGB {
		class := -1
		for i, floor := range fleetRAMClassFloors {
			if gb >= floor {
				class = i
			}
		}
		if class >= 0 {
			counts[class]++
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
		// Complementary suppression: also hide the smallest emitted class.
		smallest := -1
		for i, n := range counts {
			if suppressed[i] {
				continue
			}
			if smallest < 0 || n < counts[smallest] {
				smallest = i
			}
		}
		if smallest >= 0 {
			suppressed[smallest] = true
		}
	}
	out := FleetRAM{
		WindowStart:   windowStart.UTC().Format(time.RFC3339),
		WindowEnd:     windowEnd.UTC().Format(time.RFC3339),
		KAnonymityMin: k,
		ProviderTotal: len(memoryGB),
		Classes:       make([]FleetRAMClass, 0, len(fleetRAMClassFloors)),
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

// ErrIntakeWindowConflict reports one window_id carrying two byte
// representations; the tick fails closed (SPEC-017 §5.2b.5).
var ErrIntakeWindowConflict = errors.New("intake: one window_id carries two different windows")

// MergeIntakeWindows merges the aggregator's complete windows into the
// persisted set by window_id (SPEC-017 §5.2b.5): an id on both sides must
// carry identical bytes (else ErrIntakeWindowConflict); only complete
// windows are kept; the result is ordered by descending window_start (ties
// by id), at most intake.MaxEmittedWindows, none whose end is older than
// intake.EmissionRetention before now.
func MergeIntakeWindows(current []intake.Window, persisted []intake.Window, now time.Time) ([]intake.Window, error) {
	byID := make(map[string]intake.Window, len(current)+len(persisted))
	for _, w := range persisted {
		if w.Complete() {
			byID[w.WindowID] = w
		}
	}
	for _, w := range current {
		if !w.Complete() {
			continue
		}
		if existing, ok := byID[w.WindowID]; ok {
			a, _ := json.Marshal(existing)
			b, _ := json.Marshal(w)
			if !bytes.Equal(a, b) {
				return nil, fmt.Errorf("%w: %s", ErrIntakeWindowConflict, w.WindowID)
			}
		}
		byID[w.WindowID] = w
	}
	cutoff := now.Add(-intake.EmissionRetention)
	var windows []intake.Window
	for _, w := range byID {
		if end, err := time.Parse(time.RFC3339, *w.WindowEnd); err != nil || end.Before(cutoff) {
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
	// one that was already recorded (SPEC-017 §5.2b.5).
	var persisted intake.UnmatchedModels
	{
		var raw []byte
		err := tx.QueryRowContext(ctx, `SELECT unmatched_models FROM stats_intake_current WHERE singleton = TRUE`).Scan(&raw)
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
	current.Windows = merged
	if current.Windows == nil {
		current.Windows = []intake.Window{}
	}

	windowStart := now.Add(-30 * 24 * time.Hour)
	memoryGB, err := activeProviderMemory(ctx, tx, windowStart)
	if err != nil {
		return err
	}
	fleet := BuildFleetRAM(memoryGB, windowStart, now, intake.KAnonymityMin)

	unmatchedJSON, err := json.Marshal(current)
	if err != nil {
		return fmt.Errorf("intake unmatched marshal: %w", err)
	}
	fleetJSON, err := json.Marshal(fleet)
	if err != nil {
		return fmt.Errorf("intake fleet marshal: %w", err)
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
// active in the trailing window (SPEC-017 §5.2b.6): a verified hardware
// profile whose last_reported_at falls inside the window. Only memory
// values are read.
func activeProviderMemory(ctx context.Context, tx *sql.Tx, windowStart time.Time) ([]int, error) {
	rows, err := tx.QueryContext(ctx, `
        SELECT ph.unified_memory_gb
          FROM provider_hardware_profiles ph
         WHERE ph.provider_id <> ''
           AND ph.verified = TRUE
           AND ph.last_reported_at >= $1
    `, windowStart)
	if err != nil {
		return nil, fmt.Errorf("intake fleet query: %w", err)
	}
	defer rows.Close()
	var out []int
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
