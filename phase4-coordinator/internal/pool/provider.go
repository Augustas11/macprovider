package pool

import (
	"net"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

type State string

const (
	StateReady       State = "ready"
	StateBusy        State = "busy"
	StateDegraded    State = "degraded"
	StateDraining    State = "draining"
	StateUnavailable State = "unavailable"
)

type Provider struct {
	ProviderID            string    `json:"provider_id"`
	AssignedID            string    `json:"assigned_id"`
	Hostname              string    `json:"hostname"`
	ModelID               string    `json:"model_id"`
	ModelParamsB          float64   `json:"model_params_b"`
	RAMGB                 int       `json:"ram_gb"`
	MaxContextTokens      int       `json:"max_context_tokens"`
	MaxConcurrency        int       `json:"max_concurrency"`
	SlotsFree             int       `json:"slots_free"`
	SlotsTotal            int       `json:"slots_total"`
	ThroughputTPSEstimate float64   `json:"throughput_tps_estimate"`
	EndpointURL           string    `json:"endpoint_url"`
	State                 State     `json:"state"`
	LastHeartbeatAt       time.Time `json:"last_heartbeat_at"`
	ConnectedAt           time.Time `json:"connected_at"`
	BinaryVersion         string    `json:"binary_version"`

	conn net.Conn
}

func (p Provider) RoutingEligible() bool {
	return p.State == StateReady && p.SlotsFree > 0
}

type Registry struct {
	mu          sync.RWMutex
	providers   map[string]*Provider
	sessions    map[string]*Provider
	endpoints   map[string]config.ProviderConfig
	seenModels  map[string]struct{}
	maxProvider int
}

func NewRegistry(providers []config.ProviderConfig) *Registry {
	endpoints := make(map[string]config.ProviderConfig, len(providers))
	for _, p := range providers {
		endpoints[p.ProviderID] = p
	}
	return &Registry{
		providers:  map[string]*Provider{},
		sessions:   map[string]*Provider{},
		endpoints:  endpoints,
		seenModels: map[string]struct{}{},
	}
}

func (r *Registry) Endpoint(providerID string) (config.ProviderConfig, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.endpoints[providerID]
	return p, ok
}

func (r *Registry) Register(p *Provider, conn net.Conn) (old net.Conn) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if existing := r.providers[p.ProviderID]; existing != nil {
		old = existing.conn
		delete(r.sessions, existing.AssignedID)
	}
	p.conn = conn
	r.providers[p.ProviderID] = p
	r.sessions[p.AssignedID] = p
	r.seenModels[p.ModelID] = struct{}{}
	return old
}

func (r *Registry) MarkState(providerID, assignedID string, state State) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	p.State = state
	return true
}

func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

type HeartbeatUpdate struct {
	Status                State
	ModelID               string
	ModelParamsB          float64
	RAMGB                 int
	MaxContextTokens      int
	MaxConcurrency        int
	SlotsFree             int
	SlotsTotal            int
	ThroughputTPSEstimate float64
	At                    time.Time
}

func (r *Registry) ApplyHeartbeat(providerID string, hb HeartbeatUpdate) (*Provider, time.Duration, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil {
		return nil, 0, false
	}
	prev := p.LastHeartbeatAt
	p.LastHeartbeatAt = hb.At
	p.ModelID = hb.ModelID
	p.ModelParamsB = hb.ModelParamsB
	p.RAMGB = hb.RAMGB
	p.MaxContextTokens = hb.MaxContextTokens
	p.MaxConcurrency = hb.MaxConcurrency
	p.SlotsFree = hb.SlotsFree
	p.SlotsTotal = hb.SlotsTotal
	p.ThroughputTPSEstimate = hb.ThroughputTPSEstimate
	r.seenModels[hb.ModelID] = struct{}{}
	if hb.Status != "" && hb.Status != p.State {
		p.State = hb.Status
	}
	cp := *p
	var gap time.Duration
	if !prev.IsZero() {
		gap = hb.At.Sub(prev)
	}
	return &cp, gap, true
}

func (r *Registry) ModelKnown(modelID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if _, ok := r.seenModels[modelID]; ok {
		return true
	}
	for _, p := range r.providers {
		if p.ModelID == modelID {
			return true
		}
	}
	return false
}

type StateUpdate struct {
	State      State
	SlotsFree  *int
	SlotsTotal *int
}

func (r *Registry) ApplyStateUpdate(providerID string, update StateUpdate) (*Provider, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil {
		return nil, false
	}
	p.State = update.State
	if update.SlotsFree != nil {
		p.SlotsFree = *update.SlotsFree
	}
	if update.SlotsTotal != nil {
		p.SlotsTotal = *update.SlotsTotal
	}
	cp := *p
	return &cp, true
}

func (r *Registry) RemoveIfSession(providerID, assignedID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	delete(r.providers, providerID)
	delete(r.sessions, assignedID)
	return true
}

func (r *Registry) Snapshot() []Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Provider, 0, len(r.providers))
	for _, p := range r.providers {
		cp := *p
		cp.conn = nil
		out = append(out, cp)
	}
	return out
}
