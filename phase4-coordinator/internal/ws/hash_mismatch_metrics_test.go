package ws

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/rs/zerolog"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestObserveHashStatusTransitionIncrementsMismatchMetric(t *testing.T) {
	t.Parallel()
	reg := prometheus.NewRegistry()
	metrics := statsmetrics.New(reg)
	server := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(), WithModelHashMismatchMetrics(metrics))

	server.observeHashStatusTransition(pool.HashStatusVerified, pool.HashStatusVerified, "p", "a", "m", "h")
	if got := modelHashMismatchMetricValue(t, reg); got != 0 {
		t.Fatalf("verified->verified metric = %v, want 0", got)
	}
	server.observeHashStatusTransition(pool.HashStatusVerified, pool.HashStatusMismatch, "p", "a", "m", "h")
	if got := modelHashMismatchMetricValue(t, reg); got != 1 {
		t.Fatalf("verified->mismatch metric = %v, want 1", got)
	}
	server.observeHashStatusTransition(pool.HashStatusMismatch, pool.HashStatusMismatch, "p", "a", "m", "h")
	if got := modelHashMismatchMetricValue(t, reg); got != 1 {
		t.Fatalf("mismatch->mismatch metric = %v, want 1", got)
	}
}

func modelHashMismatchMetricValue(t *testing.T, reg *prometheus.Registry) float64 {
	t.Helper()
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	for _, mf := range families {
		if mf.GetName() != "model_hash_mismatch_total" {
			continue
		}
		for _, metric := range mf.GetMetric() {
			return metric.GetCounter().GetValue()
		}
	}
	return 0
}
