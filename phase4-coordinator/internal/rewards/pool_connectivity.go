package rewards

import (
	"net/http"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// PoolHeartbeatBridge evaluates uptime via live pool heartbeats.
type PoolHeartbeatBridge struct {
	snapshot func() []pool.Provider
	maxGap   time.Duration
}

// NewPoolHeartbeatBridge returns connectivity backed by pool snapshots.
func NewPoolHeartbeatBridge(snapshot func() []pool.Provider) *PoolHeartbeatBridge {
	return &PoolHeartbeatBridge{
		snapshot: snapshot,
		maxGap:   uptimeGapThreshold,
	}
}

// HeartbeatOK reports whether the provider heartbeat is fresh.
func (b *PoolHeartbeatBridge) HeartbeatOK(providerID string, now time.Time) bool {
	if b == nil || b.snapshot == nil {
		return false
	}
	for _, p := range b.snapshot() {
		if p.ProviderID != providerID {
			continue
		}
		if p.LastHeartbeatAt.IsZero() {
			return false
		}
		return now.Sub(p.LastHeartbeatAt) <= b.maxGap
	}
	return false
}

// TrustPromotionMux mounts trust admin routes on the provider mux.
func TrustPromotionMux(deps TrustAdminDeps) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/admin/trust-promotion/request", NewTrustPromotionRequestHandler(deps))
	mux.Handle("/admin/trust-promotion/", NewTrustPromotionApproveHandler(deps))
	return mux
}
