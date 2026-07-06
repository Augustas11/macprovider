package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"

	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
	"github.com/rs/zerolog"
)

func TestRunNightlyRebuildOnceRecoversPanicAndEmitsMetrics(t *testing.T) {
	orig := runNightlyRebuildForRunner
	t.Cleanup(func() { runNightlyRebuildForRunner = orig })
	runNightlyRebuildForRunner = func(context.Context, *sql.DB, Config, zerolog.Logger) error {
		panic(fmt.Errorf("synthetic nightly panic"))
	}

	reg := prometheus.NewRegistry()
	m := statsmetrics.New(reg)
	r := &Runner{
		cfg: Config{
			PanicBackoff: time.Millisecond,
		}.DefaultsApplied(),
		metrics: m,
		logger:  zerolog.Nop(),
	}

	start := time.Now()
	err := r.runNightlyRebuildOnce(context.Background())
	if err == nil || !strings.Contains(err.Error(), "nightly rebuild panic") {
		t.Fatalf("runNightlyRebuildOnce err=%v want panic classification", err)
	}
	if time.Since(start) < time.Millisecond {
		t.Fatal("runNightlyRebuildOnce returned before panic_backoff elapsed")
	}

	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather metrics: %v", err)
	}
	for _, comp := range []string{"leaderboard_30d", "leaderboard_all"} {
		if got := counterValue(t, families, "stats_rollup_panic_total", "component", comp); got != 1 {
			t.Fatalf("panic counter %s=%v want 1", comp, got)
		}
		if got := counterValue(t, families, "stats_rollup_errors_total", "component", comp); got != 1 {
			t.Fatalf("error counter %s=%v want 1", comp, got)
		}
	}

	runNightlyRebuildForRunner = func(context.Context, *sql.DB, Config, zerolog.Logger) error {
		return nil
	}
	if err := r.runNightlyRebuildOnce(context.Background()); err != nil {
		t.Fatalf("second run after recovered panic err=%v want nil", err)
	}
}

func counterValue(t *testing.T, families []*dto.MetricFamily, name, labelName, labelValue string) float64 {
	t.Helper()
	for _, family := range families {
		if family.GetName() != name {
			continue
		}
		for _, metric := range family.GetMetric() {
			for _, label := range metric.GetLabel() {
				if label.GetName() == labelName && label.GetValue() == labelValue {
					return metric.GetCounter().GetValue()
				}
			}
		}
	}
	return 0
}
