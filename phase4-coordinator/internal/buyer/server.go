package buyer

import (
	"encoding/json"
	"net/http"
	"sort"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/go-chi/chi/v5"
	"github.com/rs/zerolog"
)

type Server struct {
	pool      *pool.Registry
	log       zerolog.Logger
	createdAt int64
}

func NewServer(registry *pool.Registry, logger zerolog.Logger, startedAt time.Time) *Server {
	return &Server{
		pool:      registry,
		log:       logger,
		createdAt: startedAt.Unix(),
	}
}

func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.Get("/v1/models", s.handleModels)
	return r
}

type modelsResponse struct {
	Object string       `json:"object"`
	Data   []modelEntry `json:"data"`
}

type modelEntry struct {
	ID               string `json:"id"`
	Object           string `json:"object"`
	Created          int64  `json:"created"`
	OwnedBy          string `json:"owned_by"`
	ProviderCount    int    `json:"provider_count"`
	MaxContextTokens int    `json:"max_context_tokens"`
	TotalSlots       int    `json:"total_slots"`
}

func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	models := map[string]modelEntry{}
	for _, p := range s.pool.Snapshot() {
		if p.State != pool.StateReady {
			continue
		}
		entry := models[p.ModelID]
		if entry.ID == "" {
			entry = modelEntry{
				ID:      p.ModelID,
				Object:  "model",
				Created: s.createdAt,
				OwnedBy: "macprovider",
			}
		}
		entry.ProviderCount++
		if p.MaxContextTokens > entry.MaxContextTokens {
			entry.MaxContextTokens = p.MaxContextTokens
		}
		entry.TotalSlots += p.SlotsTotal
		models[p.ModelID] = entry
	}

	data := make([]modelEntry, 0, len(models))
	for _, entry := range models {
		data = append(data, entry)
	}
	sort.Slice(data, func(i, j int) bool {
		return data[i].ID < data[j].ID
	})

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(modelsResponse{Object: "list", Data: data}); err != nil {
		s.log.Warn().Err(err).Msg("write models response failed")
	}
}
