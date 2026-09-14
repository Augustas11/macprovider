package pool

// TryPinModelAdmissionProvider returns an owned authority view while retaining
// the registry read lock. The caller must release exactly once after its
// serialized decision, and must not call registry getters or callbacks while
// pinned. Contention and missing exact connected sessions fail without a pin.
// Readiness/exclusions remain the admission resolver's policy, not a new pool
// eligibility rule (ordinary activity counters do not prevent a pin).
func (r *Registry) TryPinModelAdmissionProvider(providerID, assignedID string) (provider Provider, sanctioned bool, release func(), ok bool) {
	if r == nil || providerID == "" || assignedID == "" || !r.mu.TryRLock() {
		return Provider{}, false, nil, false
	}
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID || r.sessions[assignedID] != p || p.conn == nil {
		r.mu.RUnlock()
		return Provider{}, false, nil, false
	}
	view := cloneProviderSnapshot(p)
	view.conn = nil
	view.Tier2Session = nil
	return view, r.canarySanctions[providerID].failCount > 0, r.mu.RUnlock, true
}

// cloneProviderSnapshot owns value metadata. Tier2Session remains owned by the
// encrypted-stream lifecycle; callers requiring immutable admission data omit it.
func cloneProviderSnapshot(p *Provider) Provider {
	view := *p
	view.ReceiptPubkey = cloneBytes(p.ReceiptPubkey)
	view.PendingReceiptPubkey = cloneBytes(p.PendingReceiptPubkey)
	view.ReceiptPubkeyPrev = cloneReceiptPubkeyPrevious(p.ReceiptPubkeyPrev)
	view.SEPublicKey = cloneBytes(p.SEPublicKey)
	view.MDABoundSEKeyHash = cloneBytes(p.MDABoundSEKeyHash)
	view.SupportedModels = append([]string(nil), p.SupportedModels...)
	view.LastAutoupdateEvent = cloneBytes(p.LastAutoupdateEvent)
	view.CanaryLastCheckedAt = cloneTimePtr(p.CanaryLastCheckedAt)
	view.CanaryLastFailedAt = cloneTimePtr(p.CanaryLastFailedAt)
	view.LastBuyerSuccessAt = cloneTimePtr(p.LastBuyerSuccessAt)
	view.HardwareCapacity = cloneProviderHardwareCapacity(p.HardwareCapacity)
	view.SafetyTelemetry = cloneProviderSafetyTelemetry(p.SafetyTelemetry)
	if view.SafetyTelemetry != nil {
		if p.SafetyTelemetry.CPUUtilizationPct != nil {
			value := *p.SafetyTelemetry.CPUUtilizationPct
			view.SafetyTelemetry.CPUUtilizationPct = &value
		}
		if p.SafetyTelemetry.GPUUtilizationPct != nil {
			value := *p.SafetyTelemetry.GPUUtilizationPct
			view.SafetyTelemetry.GPUUtilizationPct = &value
		}
	}
	if p.ModelClassOPoIPass != nil {
		value := *p.ModelClassOPoIPass
		view.ModelClassOPoIPass = &value
	}
	return view
}
