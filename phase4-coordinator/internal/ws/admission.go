package ws

import (
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
)

type AdmissionManager struct {
	mu             sync.Mutex
	cfg            config.AdmissionConfig
	now            func() time.Time
	admissions     []time.Time
	records        map[string]*ProvisionalRecord
	rejected       map[string]string
	requestWindows map[string][]time.Time
}

type ProvisionalRecord struct {
	ProviderID          string     `json:"provider_id"`
	Hostname            string     `json:"hostname"`
	ModelID             string     `json:"model_id"`
	BinaryVersion       string     `json:"binary_version"`
	FirstSeenAt         time.Time  `json:"first_seen_at"`
	LastSeenAt          time.Time  `json:"last_seen_at"`
	TotalRequestsServed int        `json:"total_requests_served"`
	TotalTokensServed   int        `json:"total_tokens_served"`
	PromotedAt          *time.Time `json:"promoted_at"`
	CurrentlyConnected  bool       `json:"currently_connected"`
}

func NewAdmissionManager(cfg config.AdmissionConfig, now func() time.Time) *AdmissionManager {
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}
	return &AdmissionManager{
		cfg:            cfg,
		now:            now,
		records:        map[string]*ProvisionalRecord{},
		rejected:       map[string]string{},
		requestWindows: map[string][]time.Time{},
	}
}

func (a *AdmissionManager) Admit(hello Hello, pinned bool, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) {
	if pinned {
		return pool.TierPinned, 0, ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, ok := a.rejected[hello.ProviderID]; ok {
		return pool.TierRejected, CloseBanned, "banned: provider " + hello.ProviderID + " has been rejected by operator"
	}
	if a.cfg.PinnedOnly {
		return pool.TierRejected, CloseBanned, "banned: provider " + hello.ProviderID + " has been rejected by operator"
	}
	now := a.now()
	cutoff := now.Add(-time.Hour)
	a.admissions = keepAfter(a.admissions, cutoff)
	if connectedProvisional >= a.cfg.ProvisionalPoolMax {
		return pool.TierProvisional, CloseProvisionalPoolFull, "provisional_pool_full: max " + itoa(a.cfg.ProvisionalPoolMax) + " provisional providers reached"
	}
	if _, known := a.records[hello.ProviderID]; !known && len(a.admissions) >= a.cfg.ProvisionalAdmissionRatePerHour {
		return pool.TierProvisional, CloseProvisionalRateLimited, "provisional_rate_limited: max " + itoa(a.cfg.ProvisionalAdmissionRatePerHour) + " admissions per hour"
	}
	rec := a.records[hello.ProviderID]
	if rec == nil {
		rec = &ProvisionalRecord{
			ProviderID:          hello.ProviderID,
			FirstSeenAt:         now,
			TotalRequestsServed: 0,
		}
		a.records[hello.ProviderID] = rec
		a.admissions = append(a.admissions, now)
	}
	rec.LastSeenAt = now
	rec.Hostname = hello.Hostname
	rec.ModelID = hello.ModelID
	rec.BinaryVersion = hello.BinaryVersion
	return pool.TierProvisional, 0, ""
}

func (a *AdmissionManager) CheckQuota(provider pool.Provider) bool {
	if provider.Tier != pool.TierProvisional {
		return true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	cutoff := a.now().Add(-time.Hour)
	window := keepAfter(a.requestWindows[provider.ProviderID], cutoff)
	a.requestWindows[provider.ProviderID] = window
	return len(window) < a.cfg.ProvisionalQuotaPerHour
}

func (a *AdmissionManager) RecordRequest(provider pool.Provider) {
	_ = a.TryReserveRequest(provider)
}

func (a *AdmissionManager) TryReserveRequest(provider pool.Provider) bool {
	if provider.Tier != pool.TierProvisional {
		return true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	window := keepAfter(a.requestWindows[provider.ProviderID], now.Add(-time.Hour))
	if len(window) >= a.cfg.ProvisionalQuotaPerHour {
		a.requestWindows[provider.ProviderID] = window
		return false
	}
	a.requestWindows[provider.ProviderID] = append(window, now)
	if rec := a.records[provider.ProviderID]; rec != nil {
		rec.TotalRequestsServed++
		rec.LastSeenAt = now
	}
	return true
}

func (a *AdmissionManager) RefundRequest(provider pool.Provider) {
	if provider.Tier != pool.TierProvisional {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	window := a.requestWindows[provider.ProviderID]
	if len(window) > 0 {
		a.requestWindows[provider.ProviderID] = window[:len(window)-1]
	}
	if rec := a.records[provider.ProviderID]; rec != nil && rec.TotalRequestsServed > 0 {
		rec.TotalRequestsServed--
	}
}

func (a *AdmissionManager) Promote(providerID string) (string, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	rec := a.records[providerID]
	if rec == nil {
		return "", false
	}
	now := a.now()
	rec.PromotedAt = &now
	return string(pool.TierProvisional), true
}

func (a *AdmissionManager) Reject(providerID, reason string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.rejected[providerID] = reason
}

func (a *AdmissionManager) Rejected(providerID string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	_, ok := a.rejected[providerID]
	return ok
}

func (a *AdmissionManager) Records(connected map[string]bool) []ProvisionalRecord {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]ProvisionalRecord, 0, len(a.records))
	for _, rec := range a.records {
		cp := *rec
		cp.CurrentlyConnected = connected[rec.ProviderID]
		out = append(out, cp)
	}
	return out
}

func keepAfter(in []time.Time, cutoff time.Time) []time.Time {
	i := 0
	for ; i < len(in); i++ {
		if in[i].After(cutoff) {
			break
		}
	}
	if i == 0 {
		return in
	}
	out := append([]time.Time(nil), in[i:]...)
	return out
}
