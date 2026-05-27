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

type Registry struct {
	mu          sync.RWMutex
	providers   map[string]*Provider
	sessions    map[string]*Provider
	endpoints   map[string]config.ProviderConfig
	maxProvider int
}

func NewRegistry(providers []config.ProviderConfig) *Registry {
	endpoints := make(map[string]config.ProviderConfig, len(providers))
	for _, p := range providers {
		endpoints[p.ProviderID] = p
	}
	return &Registry{
		providers: map[string]*Provider{},
		sessions:  map[string]*Provider{},
		endpoints: endpoints,
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
	return old
}

func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}
