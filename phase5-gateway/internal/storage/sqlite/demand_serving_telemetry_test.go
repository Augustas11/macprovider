package sqlite

import (
	"context"
	"database/sql"
	"path/filepath"
	"strconv"
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

func TestDemandServingTelemetryRejectsUnknownLabels(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	event := storage.DemandEvent{RequestID: "req_bad", BuyerHash: "b", TrafficClass: "paid", RequestedModel: "llama",
		TerminalResult: "success", ServingEngine: "shard_group", CreatedAt: fixedTime()}
	if err := store.InsertDemandEvent(ctx, event); err == nil {
		t.Fatal("serving_engine outside the closed vocabulary was stored")
	}
	event.ServingEngine, event.StreamingMode = "", "buffered_whatever"
	if err := store.InsertDemandEvent(ctx, event); err == nil {
		t.Fatal("streaming_mode outside the closed vocabulary was stored")
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
