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

// An existing demand_events table gains the SPEC-006-R028 columns on Open,
// its rows read NULL (and the label defaults), and a second Open is a no-op.
func TestDemandServingTelemetryColumnsMigrateOldTableIdempotently(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	raw, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	if _, err := raw.ExecContext(ctx, demandEventsDDL); err != nil {
		t.Fatalf("old demand_events: %v", err)
	}
	if _, err := raw.ExecContext(ctx, `
		INSERT INTO demand_events(request_id, buyer_hash, traffic_class, requested_model, stream, structured_output,
			tools_requested, terminal_result, eligible_provider_exists, substituted, time_to_first_token_ms, created_at)
		VALUES('req_old', 'buyer', 'paid', 'llama', 1, 0, 0, 'success', 1, 0, 42, ?)`, encodeTime(fixedTime())); err != nil {
		t.Fatalf("old row: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	for open := 1; open <= 2; open++ {
		store, err := Open(ctx, path)
		if err != nil {
			t.Fatalf("Open #%d: %v", open, err)
		}
		var reasoning, answer, rate, queue sql.NullInt64
		var mode, engine string
		var legacyTTFT int64
		err = store.db.QueryRowContext(ctx, `
			SELECT gw_first_reasoning_ms, gw_first_answer_ms, gw_output_tps_millitokens, streaming_mode, serving_engine,
				provider_reported_queue_ms, time_to_first_token_ms
			FROM demand_events WHERE request_id = 'req_old'`).Scan(&reasoning, &answer, &rate, &mode, &engine, &queue, &legacyTTFT)
		if err != nil {
			t.Fatalf("read old row after Open #%d: %v", open, err)
		}
		if reasoning.Valid || answer.Valid || rate.Valid || queue.Valid || mode != "" || engine != "unknown" || legacyTTFT != 42 {
			t.Fatalf("old row after Open #%d = %v %v %v %v %q %q %d", open, reasoning, answer, rate, queue, mode, engine, legacyTTFT)
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

// A label value outside the stored vocabulary is stored as unknown/empty, so
// a value a validator learns to accept later can never fail the INSERT.
func TestDemandServingTelemetryMapsUnknownLabels(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	event := storage.DemandEvent{RequestID: "req_future", BuyerHash: "b", TrafficClass: "paid", RequestedModel: "llama",
		TerminalResult: "success", ServingEngine: "shard_group", StreamingMode: "buffered_future", CreatedAt: fixedTime()}
	if err := store.InsertDemandEvent(ctx, event); err != nil {
		t.Fatalf("InsertDemandEvent: %v", err)
	}
	var engine, mode string
	if err := store.db.QueryRowContext(ctx, `SELECT serving_engine, streaming_mode FROM demand_events WHERE request_id = 'req_future'`).Scan(&engine, &mode); err != nil {
		t.Fatal(err)
	}
	if engine != "unknown" || mode != "" {
		t.Fatalf("stored %q/%q, want unknown/empty", engine, mode)
	}
}

// The column CHECKs accept exactly the exported vocabularies.
func TestDemandServingTelemetryChecksMatchVocabularies(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	seq := 0
	insert := func(engine, mode string) error {
		seq++
		_, err := store.db.ExecContext(ctx, `
			INSERT INTO demand_events(request_id, buyer_hash, traffic_class, requested_model, stream, structured_output,
				tools_requested, terminal_result, eligible_provider_exists, substituted, created_at, serving_engine, streaming_mode)
			VALUES(?, 'b', 'paid', 'llama', 1, 0, 0, 'success', 1, 0, ?, ?, ?)`, "req_check_"+strconv.Itoa(seq), encodeTime(fixedTime()), engine, mode)
		return err
	}
	for _, engine := range storage.DemandServingEngines {
		if err := insert(engine, ""); err != nil {
			t.Fatalf("engine %q rejected: %v", engine, err)
		}
	}
	for _, mode := range storage.DemandStreamingModes {
		if err := insert("unknown", mode); err != nil {
			t.Fatalf("mode %q rejected: %v", mode, err)
		}
	}
	if insert("shard_group", "") == nil || insert("unknown", "buffered_future") == nil {
		t.Fatal("CHECK accepted a value outside the vocabulary")
	}
}

// A database where an earlier migration added only some R028 columns (a
// partial failure) finishes on the next Open.
func TestDemandServingTelemetryMigrationResumesAfterPartialFailure(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	raw, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.ExecContext(ctx, demandEventsDDL); err != nil {
		t.Fatal(err)
	}
	for _, column := range demandEventsServingTelemetryColumns[:3] {
		if _, err := raw.ExecContext(ctx, "ALTER TABLE demand_events ADD COLUMN "+column.name+" "+column.ddl); err != nil {
			t.Fatal(err)
		}
	}
	// The concurrent-Open path relies on SQLite's duplicate-column message.
	_, dupErr := raw.ExecContext(ctx, "ALTER TABLE demand_events ADD COLUMN "+demandEventsServingTelemetryColumns[0].name+" INTEGER")
	if dupErr == nil || !strings.Contains(dupErr.Error(), "duplicate column name: "+demandEventsServingTelemetryColumns[0].name) {
		t.Fatalf("duplicate ALTER error = %v", dupErr)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open after partial migration: %v", err)
	}
	defer store.Close()
	for _, column := range demandEventsServingTelemetryColumns {
		var n int
		if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pragma_table_info('demand_events') WHERE name = ?`, column.name).Scan(&n); err != nil || n != 1 {
			t.Fatalf("column %s count=%d err=%v", column.name, n, err)
		}
	}
}

func TestDemandLatencyPercentilesNearestRankAndSmallSamples(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	base := fixedTime()
	seq := 0
	insert := func(model, engine, terminal string, answer *int64, at time.Time) {
		t.Helper()
		seq++
		event := storage.DemandEvent{RequestID: "req_" + strconv.Itoa(seq), BuyerHash: "b", TrafficClass: "paid",
			RequestedModel: model, TerminalResult: terminal, ServingEngine: engine, StreamingMode: "incremental",
			GatewayFirstAnswerMs: answer, CreatedAt: at}
		if terminal == "failure" {
			event.FailureReason = "upstream_provider_failure"
		}
		if err := store.InsertDemandEvent(ctx, event); err != nil {
			t.Fatalf("InsertDemandEvent: %v", err)
		}
	}
	ms := func(v int64) *int64 { return &v }
	// Twenty CB samples 1..20 (inserted in reverse): p50 rank 10, p95 rank 19.
	for v := int64(20); v >= 1; v-- {
		insert("llama", "continuous_batching", "success", ms(v), base)
	}
	insert("llama", "continuous_batching", "success", nil, base)                     // absent: not a sample
	insert("llama", "continuous_batching", "failure", ms(1), base)                   // failed: excluded
	insert("llama", "continuous_batching", "success", ms(1), base.Add(-2*time.Hour)) // outside the window
	for v := int64(1); v <= 5; v++ {
		insert("llama", "native_mtp", "success", ms(v*100), base)
	}
	for v := int64(1); v <= 4; v++ {
		insert("qwen3-8b", "general_mlx", "success", ms(v), base)
	}
	for v := int64(1); v <= 30; v++ {
		insert("unknown_model_id", "unknown", "success", ms(v), base)
	}

	cells, err := store.DemandLatencyPercentiles(ctx, base.Add(-time.Hour), base.Add(time.Hour))
	if err != nil {
		t.Fatalf("DemandLatencyPercentiles: %v", err)
	}
	type want struct {
		samples  int64
		p50, p95 *int64
	}
	expected := map[string]want{
		"llama/continuous_batching": {20, ms(10), ms(19)},
		"llama/native_mtp":          {5, ms(300), nil},
		"qwen3-8b/general_mlx":      {4, nil, nil},
	}
	if len(cells) != len(expected) {
		t.Fatalf("cells = %+v, want %d", cells, len(expected))
	}
	equal := func(a, b *int64) bool { return (a == nil && b == nil) || (a != nil && b != nil && *a == *b) }
	for _, cell := range cells {
		w, ok := expected[cell.RequestedModel+"/"+cell.ServingEngine]
		if !ok {
			t.Fatalf("unexpected cell %s/%s", cell.RequestedModel, cell.ServingEngine)
		}
		q := cell.FirstAnswerMs
		if q.Samples != w.samples || !equal(q.P50, w.p50) || !equal(q.P95, w.p95) {
			t.Fatalf("%s/%s first answer = %+v (p50 %v p95 %v), want %+v", cell.RequestedModel, cell.ServingEngine, q, q.P50, q.P95, w)
		}
		if cell.FirstReasoningMs.Samples != 0 || cell.OutputTPSMilliTokens.Samples != 0 {
			t.Fatalf("absent quantities counted: %+v", cell)
		}
	}
}

// Mutation boundaries: p50 needs exactly 5 samples, p95 exactly 20.
func TestDemandLatencyPercentileSampleBoundaries(t *testing.T) {
	ctx := context.Background()
	base := fixedTime()
	for _, tc := range []struct {
		n               int
		wantP50, want95 bool
	}{{4, false, false}, {5, true, false}, {19, true, false}, {20, true, true}} {
		store := newTestStore(t)
		for i := 1; i <= tc.n; i++ {
			v := int64(i)
			if err := store.InsertDemandEvent(ctx, storage.DemandEvent{RequestID: "req_" + strconv.Itoa(i), BuyerHash: "b", TrafficClass: "paid",
				RequestedModel: "llama", TerminalResult: "success", ServingEngine: "general_mlx", GatewayFirstAnswerMs: &v, CreatedAt: base}); err != nil {
				t.Fatal(err)
			}
		}
		cells, err := store.DemandLatencyPercentiles(ctx, base.Add(-time.Hour), base.Add(time.Hour))
		if err != nil || len(cells) != 1 {
			t.Fatalf("n=%d cells=%+v err=%v", tc.n, cells, err)
		}
		q := cells[0].FirstAnswerMs
		if (q.P50 != nil) != tc.wantP50 || (q.P95 != nil) != tc.want95 {
			t.Fatalf("n=%d p50=%v p95=%v, want present %v/%v", tc.n, q.P50, q.P95, tc.wantP50, tc.want95)
		}
	}
}
