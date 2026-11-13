package sqlite

import (
	"context"
	"database/sql"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// A database already migrated to the #2340 serving-telemetry columns gains
// served_path and served_rows on Open; its rows read NULL, and a second Open
// is a no-op with the schema version unchanged.
func TestDemandServedPathColumnsMigrateR028TableIdempotently(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	raw, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	if _, err := raw.ExecContext(ctx, demandEventsDDL); err != nil {
		t.Fatalf("old demand_events: %v", err)
	}
	for _, column := range demandEventsServingTelemetryColumns {
		if strings.HasPrefix(column.name, "served_") {
			continue
		}
		if _, err := raw.ExecContext(ctx, "ALTER TABLE demand_events ADD COLUMN "+column.name+" "+column.ddl); err != nil {
			t.Fatalf("#2340 column %s: %v", column.name, err)
		}
	}
	if _, err := raw.ExecContext(ctx, `
		INSERT INTO demand_events(request_id, buyer_hash, traffic_class, requested_model, stream, structured_output,
			tools_requested, terminal_result, eligible_provider_exists, substituted, created_at, serving_engine)
		VALUES('req_r028', 'buyer', 'paid', 'llama', 1, 0, 0, 'success', 1, 0, ?, 'native_mtp')`, encodeTime(fixedTime())); err != nil {
		t.Fatalf("#2340 row: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}
	for open := 1; open <= 2; open++ {
		store, err := Open(ctx, path)
		if err != nil {
			t.Fatalf("Open #%d: %v", open, err)
		}
		var servedPath sql.NullString
		var servedRows sql.NullInt64
		var engine string
		if err := store.db.QueryRowContext(ctx, `SELECT served_path, served_rows, serving_engine FROM demand_events WHERE request_id = 'req_r028'`).Scan(&servedPath, &servedRows, &engine); err != nil {
			t.Fatalf("read row after Open #%d: %v", open, err)
		}
		if servedPath.Valid || servedRows.Valid || engine != "native_mtp" {
			t.Fatalf("row after Open #%d = %v %v %q", open, servedPath, servedRows, engine)
		}
		var version int
		if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil || version != maxKnownSchemaVersion {
			t.Fatalf("schema version = %d (%v), want unchanged %d", version, err, maxKnownSchemaVersion)
		}
		if err := store.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

// The gateway, not the column, enforces the served-path vocabulary: a path
// outside it stores unknown with no rows, rows outside 1..256 store NULL,
// and no served path stores NULL for both.
func TestDemandServedPathInsertMapping(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	rows := func(v int64) *int64 { return &v }
	for i, tc := range []struct {
		path     string
		rows     *int64
		wantPath sql.NullString
		wantRows sql.NullInt64
	}{
		{"", nil, sql.NullString{}, sql.NullInt64{}},
		{"", rows(3), sql.NullString{}, sql.NullInt64{}},
		{"continuous_batching", rows(3), sql.NullString{String: "continuous_batching", Valid: true}, sql.NullInt64{Int64: 3, Valid: true}},
		{"native_mtp", rows(256), sql.NullString{String: "native_mtp", Valid: true}, sql.NullInt64{Int64: 256, Valid: true}},
		{"serial", rows(1), sql.NullString{String: "serial", Valid: true}, sql.NullInt64{Int64: 1, Valid: true}},
		{"shard_group", rows(0), sql.NullString{String: "shard_group", Valid: true}, sql.NullInt64{}},
		{"serial", rows(257), sql.NullString{String: "serial", Valid: true}, sql.NullInt64{}},
		{"unknown", rows(4), sql.NullString{String: "unknown", Valid: true}, sql.NullInt64{}},
		{"speculative_future", rows(2), sql.NullString{String: "unknown", Valid: true}, sql.NullInt64{}},
	} {
		id := "req_served_" + strconv.Itoa(i)
		event := storage.DemandEvent{RequestID: id, BuyerHash: "b", TrafficClass: "paid", RequestedModel: "llama",
			TerminalResult: "success", ServedPath: tc.path, ServedRows: tc.rows, CreatedAt: fixedTime()}
		if err := store.InsertDemandEvent(ctx, event); err != nil {
			t.Fatalf("%d: InsertDemandEvent: %v", i, err)
		}
		var gotPath sql.NullString
		var gotRows sql.NullInt64
		if err := store.db.QueryRowContext(ctx, `SELECT served_path, served_rows FROM demand_events WHERE request_id = ?`, id).Scan(&gotPath, &gotRows); err != nil {
			t.Fatal(err)
		}
		if gotPath != tc.wantPath || gotRows != tc.wantRows {
			t.Fatalf("%d (%q, %v): stored %v %v, want %v %v", i, tc.path, tc.rows, gotPath, gotRows, tc.wantPath, tc.wantRows)
		}
	}
}

// The column CHECKs bound length and rows only; every vocabulary value fits.
func TestDemandServedPathColumnChecks(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	seq := 0
	insert := func(path any, rows any) error {
		seq++
		_, err := store.db.ExecContext(ctx, `
			INSERT INTO demand_events(request_id, buyer_hash, traffic_class, requested_model, stream, structured_output,
				tools_requested, terminal_result, eligible_provider_exists, substituted, created_at, served_path, served_rows)
			VALUES(?, 'b', 'paid', 'llama', 1, 0, 0, 'success', 1, 0, ?, ?, ?)`, "req_sp_check_"+strconv.Itoa(seq), encodeTime(fixedTime()), path, rows)
		return err
	}
	for _, path := range storage.DemandServedPaths {
		if err := insert(path, 1); err != nil {
			t.Fatalf("path %q rejected: %v", path, err)
		}
	}
	if err := insert(nil, nil); err != nil {
		t.Fatalf("NULL rejected: %v", err)
	}
	if insert(strings.Repeat("x", 33), nil) == nil || insert("serial", 0) == nil || insert("serial", 257) == nil {
		t.Fatal("CHECK accepted an over-long path or rows outside 1..256")
	}
}

// served_path_cells group by model, served path and row band, with the
// same percentile rule; rows without a served path are not in them, and
// the serving-engine cells are unchanged.
func TestDemandServedPathLatencyPercentiles(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	base := fixedTime()
	seq := 0
	insert := func(path string, rows int64, answer int64) {
		t.Helper()
		seq++
		event := storage.DemandEvent{RequestID: "req_band_" + strconv.Itoa(seq), BuyerHash: "b", TrafficClass: "paid",
			RequestedModel: "llama", TerminalResult: "success", ServingEngine: "continuous_batching", StreamingMode: "incremental",
			GatewayFirstAnswerMs: &answer, ServedPath: path, CreatedAt: base}
		if rows > 0 {
			event.ServedRows = &rows
		}
		if err := store.InsertDemandEvent(ctx, event); err != nil {
			t.Fatalf("InsertDemandEvent: %v", err)
		}
	}
	for v := int64(1); v <= 5; v++ {
		insert("continuous_batching", 1+v%2*2, v*10) // rows 1 or 3: bands 1 and 2-4
	}
	for _, rows := range []int64{5, 8, 9, 16, 17, 256} {
		insert("native_mtp", rows, 7)
	}
	insert("unknown", 0, 9)
	insert("", 0, 11) // no served path: not in served_path_cells
	cells, err := store.DemandServedPathLatencyPercentiles(ctx, base.Add(-time.Hour), base.Add(time.Hour))
	if err != nil {
		t.Fatalf("DemandServedPathLatencyPercentiles: %v", err)
	}
	var got []string
	for _, c := range cells {
		got = append(got, c.RequestedModel+"/"+c.ServedPath+"/"+c.ServedRowsBand+"="+strconv.FormatInt(c.FirstAnswerMs.Samples, 10))
	}
	want := "llama/continuous_batching/1=2,llama/continuous_batching/2-4=3,llama/native_mtp/17+=2,llama/native_mtp/5-8=2,llama/native_mtp/9-16=2,llama/unknown/unknown=1"
	if strings.Join(got, ",") != want {
		t.Fatalf("cells = %s\nwant    %s", strings.Join(got, ","), want)
	}
	if c := cells[1]; c.FirstAnswerMs.P50 != nil || c.FirstAnswerMs.P95 != nil {
		t.Fatalf("3 samples gave a percentile: %+v", c.FirstAnswerMs)
	}
	engineCells, err := store.DemandLatencyPercentiles(ctx, base.Add(-time.Hour), base.Add(time.Hour))
	if err != nil || len(engineCells) != 1 || engineCells[0].ServingEngine != "continuous_batching" || engineCells[0].FirstAnswerMs.Samples != 13 {
		t.Fatalf("serving-engine cells = %+v (%v)", engineCells, err)
	}
	// Five samples give a p50 (nearest rank 3 of 5).
	for v := int64(1); v <= 5; v++ {
		insert("serial", 1, v)
	}
	cells, err = store.DemandServedPathLatencyPercentiles(ctx, base.Add(-time.Hour), base.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range cells {
		if c.ServedPath == "serial" {
			if c.FirstAnswerMs.Samples != 5 || c.FirstAnswerMs.P50 == nil || *c.FirstAnswerMs.P50 != 3 || c.FirstAnswerMs.P95 != nil {
				t.Fatalf("serial cell = %+v", c.FirstAnswerMs)
			}
			return
		}
	}
	t.Fatal("serial cell missing")
}
