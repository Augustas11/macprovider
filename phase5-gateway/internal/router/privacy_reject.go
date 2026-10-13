package router

import (
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"sync"

	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// privacyRejectMetrics counts SPEC-049-R030 privacy-class refusals the
// gateway relays, by closed phase and reason.
type privacyRejectMetrics struct {
	mu     sync.Mutex
	counts map[[2]string]int64
}

func newPrivacyRejectMetrics() *privacyRejectMetrics {
	return &privacyRejectMetrics{counts: make(map[[2]string]int64)}
}

func (m *privacyRejectMetrics) record(phase, reason string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.counts[[2]string{phase, reason}]++
}

func (m *privacyRejectMetrics) prometheus() string {
	var b strings.Builder
	b.WriteString("# HELP gateway_privacy_route_rejections_total Privacy-class requests refused by the coordinator, by SPEC-049-R030 phase and reason.\n")
	b.WriteString("# TYPE gateway_privacy_route_rejections_total counter\n")
	if m == nil {
		return b.String()
	}
	m.mu.Lock()
	keys := make([][2]string, 0, len(m.counts))
	for key := range m.counts {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i][0] != keys[j][0] {
			return keys[i][0] < keys[j][0]
		}
		return keys[i][1] < keys[j][1]
	})
	for _, key := range keys {
		fmt.Fprintf(&b, "gateway_privacy_route_rejections_total{phase=%q,reason=%q} %d\n", key[0], key[1], m.counts[key])
	}
	m.mu.Unlock()
	return b.String()
}

// upstreamPrivacyRejectReason reads the coordinator's internal reason
// header. Anything but exactly one closed value is "other".
func upstreamPrivacyRejectReason(h http.Header) string {
	if h == nil {
		return relayblind.PrivacyRejectOther
	}
	values := h.Values(relayblind.PrivacyRejectReasonHeader)
	if len(values) != 1 {
		return relayblind.PrivacyRejectOther
	}
	return relayblind.NormalizePrivacyRejectReason(values[0])
}

// notePrivacyUpstreamRejection logs and counts one privacy-class refusal the
// coordinator returned (SPEC-049-R030). The reason header is never copied to
// the buyer: every caller writes a fresh error response.
func (s *Server) notePrivacyUpstreamRejection(resp *http.Response, phase, code string) {
	if s == nil || resp == nil || !relayblind.PrivacyRejectPhaseKnown(phase) {
		return
	}
	reason := upstreamPrivacyRejectReason(resp.Header)
	// Fixed categories only: no account, request, provider, or key data.
	slog.Info("privacy request refused", "event", "privacy_route_rejected", "phase", phase, "code", code, "reason", reason)
	s.privacyRejectMetrics.record(phase, reason)
}
