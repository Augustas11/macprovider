package ws

import (
	"context"
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
	pending        int
	records        map[string]*ProvisionalRecord
	rejected       map[string]string
	requestWindows map[string][]time.Time
	store          AdmissionStateStore
	onStoreError   func(error)
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

func (a *AdmissionManager) SetPersistence(store AdmissionStateStore, onError func(error)) {
	if store == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.store = store
	a.onStoreError = onError
	state, err := store.LoadAdmissionState(context.Background())
	if err != nil {
		a.reportStoreErrorLocked(err)
		return
	}
	if len(state.Admissions) > 0 {
		a.admissions = append([]time.Time(nil), state.Admissions...)
	}
	if len(state.Records) > 0 {
		a.records = state.Records
	}
	if len(state.Rejected) > 0 {
		a.rejected = state.Rejected
	}
	if len(state.RequestWindows) > 0 {
		a.requestWindows = state.RequestWindows
	}
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
	return a.AdmitAs(hello, requestedAdmissionTier(pinned), connectedProvisional)
}

func (a *AdmissionManager) CheckAdmit(hello Hello, pinned bool, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) {
	return a.CheckAdmitAs(hello, requestedAdmissionTier(pinned), connectedProvisional)
}

// ReserveAdmission holds in-memory pool capacity without creating durable
// admission history. A failed referral/token transaction therefore leaves no
// hourly admission record behind.
func (a *AdmissionManager) ReserveAdmission(hello Hello, pinned bool, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) {
	return a.ReserveAdmissionAs(hello, requestedAdmissionTier(pinned), connectedProvisional)
}

func (a *AdmissionManager) AdmitAs(hello Hello, tier pool.Tier, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) {
	if tier == pool.TierPinned {
		return pool.TierPinned, 0, ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.evaluateAdmissionLocked(hello, tier, connectedProvisional, true)
}

func (a *AdmissionManager) CheckAdmitAs(hello Hello, tier pool.Tier, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) {
	if tier == pool.TierPinned {
		return pool.TierPinned, 0, ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.evaluateAdmissionLocked(hello, tier, connectedProvisional, false)
}

func (a *AdmissionManager) CheckAdmitAsWithoutCapacity(hello Hello, tier pool.Tier) (pool.Tier, gobwas.StatusCode, string) {
	if tier == pool.TierPinned {
		return pool.TierPinned, 0, ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	tier = normalizeAdmissionTier(tier)
	if _, ok := a.rejected[hello.ProviderID]; ok {
		return pool.TierRejected, CloseBanned, "banned: provider " + hello.ProviderID + " has been rejected by operator"
	}
	if a.cfg.PinnedOnly {
		return pool.TierRejected, CloseBanned, "banned: provider " + hello.ProviderID + " has been rejected by operator"
	}
	return tier, 0, ""
}

func (a *AdmissionManager) ReserveAdmissionAs(hello Hello, tier pool.Tier, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) {
	if tier == pool.TierPinned {
		return pool.TierPinned, 0, ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	tier, code, reason := a.evaluateAdmissionLocked(hello, tier, connectedProvisional, false)
	if code == 0 && tier == pool.TierProvisional {
		a.pending++
	}
	return tier, code, reason
}

func (a *AdmissionManager) CommitReservedAdmission(hello Hello, pinned bool) pool.Tier {
	return a.CommitReservedAdmissionAs(hello, requestedAdmissionTier(pinned))
}

func (a *AdmissionManager) CommitReservedAdmissionAs(hello Hello, tier pool.Tier) pool.Tier {
	if tier == pool.TierPinned {
		return pool.TierPinned
	}
	if tier != pool.TierProvisional {
		return tier
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.recordAdmissionLocked(hello, a.now())
	return pool.TierProvisional
}

func requestedAdmissionTier(pinned bool) pool.Tier {
	if pinned {
		return pool.TierPinned
	}
	return pool.TierProvisional
}

func normalizeAdmissionTier(tier pool.Tier) pool.Tier {
	switch tier {
	case pool.TierPinned, pool.TierTrusted, pool.TierProvisional:
		return tier
	default:
		return pool.TierProvisional
	}
}

func (a *AdmissionManager) evaluateAdmissionLocked(hello Hello, tier pool.Tier, connectedProvisional int, record bool) (pool.Tier, gobwas.StatusCode, string) {
	tier = normalizeAdmissionTier(tier)
	if _, ok := a.rejected[hello.ProviderID]; ok {
		return pool.TierRejected, CloseBanned, "banned: provider " + hello.ProviderID + " has been rejected by operator"
	}
	if a.cfg.PinnedOnly {
		return pool.TierRejected, CloseBanned, "banned: provider " + hello.ProviderID + " has been rejected by operator"
	}
	if tier != pool.TierProvisional {
		return tier, 0, ""
	}
	now := a.now()
	cutoff := now.Add(-time.Hour)
	a.admissions = keepAfter(a.admissions, cutoff)
	if connectedProvisional+a.pending >= a.cfg.ProvisionalPoolMax {
		return pool.TierProvisional, CloseProvisionalPoolFull, "provisional_pool_full: max " + itoa(a.cfg.ProvisionalPoolMax) + " provisional providers reached"
	}
	if _, known := a.records[hello.ProviderID]; !known && len(a.admissions) >= a.cfg.ProvisionalAdmissionRatePerHour {
		return pool.TierProvisional, CloseProvisionalRateLimited, "provisional_rate_limited: max " + itoa(a.cfg.ProvisionalAdmissionRatePerHour) + " admissions per hour"
	}
	if !record {
		return pool.TierProvisional, 0, ""
	}
	a.pending++
	a.recordAdmissionLocked(hello, now)
	return pool.TierProvisional, 0, ""
}

func (a *AdmissionManager) recordAdmissionLocked(hello Hello, now time.Time) {
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
	a.persistLocked()
}

func (a *AdmissionManager) ReleasePendingProvisional() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.pending > 0 {
		a.pending--
	}
}

func (a *AdmissionManager) CheckQuota(provider pool.Provider) bool {
	limit, capped := a.requestQuotaLimit(provider)
	if !capped {
		return true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	cutoff := a.now().Add(-time.Hour)
	window := keepAfter(a.requestWindows[provider.ProviderID], cutoff)
	a.requestWindows[provider.ProviderID] = window
	return len(window) < limit
}

func (a *AdmissionManager) RecordRequest(provider pool.Provider) {
	_ = a.TryReserveRequest(provider)
}

func (a *AdmissionManager) TryReserveRequest(provider pool.Provider) bool {
	limit, capped := a.requestQuotaLimit(provider)
	if !capped {
		return true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	window := keepAfter(a.requestWindows[provider.ProviderID], now.Add(-time.Hour))
	if len(window) >= limit {
		a.requestWindows[provider.ProviderID] = window
		return false
	}
	a.requestWindows[provider.ProviderID] = append(window, now)
	if rec := a.records[provider.ProviderID]; rec != nil {
		rec.TotalRequestsServed++
		rec.LastSeenAt = now
	}
	a.persistLocked()
	return true
}

func (a *AdmissionManager) RefundRequest(provider pool.Provider) {
	if _, capped := a.requestQuotaLimit(provider); !capped {
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
	a.persistLocked()
}

func (a *AdmissionManager) RequestQuotaMetered(provider pool.Provider) bool {
	_, capped := a.requestQuotaLimit(provider)
	return capped
}

func (a *AdmissionManager) requestQuotaLimit(provider pool.Provider) (int, bool) {
	switch provider.Tier {
	case pool.TierProvisional:
		return a.cfg.ProvisionalQuotaPerHour, true
	case pool.TierTrusted:
		if a.cfg.TrustedQuotaPerHour > 0 {
			return a.cfg.TrustedQuotaPerHour, true
		}
	}
	return 0, false
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
	a.persistLocked()
	return string(pool.TierProvisional), true
}

// Reject marks a provisional provider as banned by the operator.
//
// REJECTION POLICY (M2-5 follow-up to codex security-audit Low #47):
// rejections have TTL semantics keyed to the provisional record's
// lifetime — Prune drops a rejection whose underlying record is past
// ProvisionalRetentionDays (default 30d). The operator's effective
// intent is "ban this activity," not "ban this provider_id forever":
// if the provider does not reappear inside the retention window, the
// rejection lapses; if they reappear within it, the rejection still
// blocks them. A durable, identity-forever blocklist is intentionally
// NOT this code path — that belongs in a separate operator-managed
// blocklist (M3 follow-up, not yet built).
func (a *AdmissionManager) Reject(providerID, reason string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.rejected[providerID] = reason
	a.persistLocked()
}

// Unreject removes an operator rejection and persists the recovery so the
// provider can reconnect after a false-positive sanction or operator review.
// The operation is idempotent; false means there was no rejection to remove.
func (a *AdmissionManager) Unreject(providerID string) (bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	reason, ok := a.rejected[providerID]
	if !ok {
		return false, nil
	}
	delete(a.rejected, providerID)
	if err := a.saveLocked(); err != nil {
		a.rejected[providerID] = reason
		a.reportStoreErrorLocked(err)
		return false, err
	}
	return true, nil
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

// Prune drops provisional state older than cutoff:
//   - records with LastSeenAt strictly before cutoff (the provider hasn't
//     re-admitted within the retention window)
//   - per-provider request-window timestamps strictly before cutoff
//   - operator-rejected entries whose record was pruned (rejections
//     expire alongside the provisional record they were aimed at —
//     if the provider re-appears later it goes through the rate-limiter
//     fresh, which is the operator's effective intent: the rejection
//     was about the activity, not the identity-forever)
//   - admission timestamps strictly before cutoff
//
// On every removal the SQLite persistence blob is rewritten so a restart
// reads the pruned state directly. Returns the number of records,
// rejected entries, and total time-points removed (admissions +
// requestWindow entries). M2-5 / XPERF-2: wired into the daily retention
// loop in cmd/coordinator/main.go alongside the request_log + audit_log
// pruners.
func (a *AdmissionManager) Prune(cutoff time.Time) (deletedRecords, deletedRejected, deletedTimePoints int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for id, rec := range a.records {
		if rec == nil || rec.LastSeenAt.Before(cutoff) {
			delete(a.records, id)
			delete(a.requestWindows, id)
			deletedRecords++
		}
	}
	for id := range a.rejected {
		if _, hasRecord := a.records[id]; !hasRecord {
			delete(a.rejected, id)
			deletedRejected++
		}
	}
	for id, window := range a.requestWindows {
		before := len(window)
		pruned := keepAfter(window, cutoff)
		if len(pruned) == 0 {
			delete(a.requestWindows, id)
		} else {
			a.requestWindows[id] = pruned
		}
		deletedTimePoints += before - len(pruned)
	}
	beforeAdmissions := len(a.admissions)
	a.admissions = keepAfter(a.admissions, cutoff)
	deletedTimePoints += beforeAdmissions - len(a.admissions)
	if deletedRecords > 0 || deletedRejected > 0 || deletedTimePoints > 0 {
		a.persistLocked()
	}
	return deletedRecords, deletedRejected, deletedTimePoints
}

func (a *AdmissionManager) persistLocked() {
	if err := a.saveLocked(); err != nil {
		a.reportStoreErrorLocked(err)
	}
}

func (a *AdmissionManager) saveLocked() error {
	if a.store == nil {
		return nil
	}
	return a.store.SaveAdmissionState(context.Background(), AdmissionState{
		Admissions:     append([]time.Time(nil), a.admissions...),
		Records:        cloneAdmissionRecords(a.records),
		Rejected:       cloneStringMap(a.rejected),
		RequestWindows: cloneTimeWindows(a.requestWindows),
	})
}

func (a *AdmissionManager) reportStoreErrorLocked(err error) {
	if a.onStoreError != nil {
		a.onStoreError(err)
	}
}

func cloneAdmissionRecords(in map[string]*ProvisionalRecord) map[string]*ProvisionalRecord {
	out := make(map[string]*ProvisionalRecord, len(in))
	for k, v := range in {
		if v == nil {
			continue
		}
		cp := *v
		out[k] = &cp
	}
	return out
}

func cloneStringMap(in map[string]string) map[string]string {
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func cloneTimeWindows(in map[string][]time.Time) map[string][]time.Time {
	out := make(map[string][]time.Time, len(in))
	for k, v := range in {
		out[k] = append([]time.Time(nil), v...)
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
