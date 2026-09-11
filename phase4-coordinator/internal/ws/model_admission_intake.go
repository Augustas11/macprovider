package ws

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"time"
)

// SPEC-047 v0.1.6 — GET /admin/model-admission/intake: the SPEC-023
// §16.2(b) `distinct_provider_offer_count` source. A materialized snapshot,
// rebuilt on a fixed cadence under a work ceiling, of distinct
// sanction-excluded providers per catalog key over the trailing 30 days,
// counted from offer-time catalog_matched offers and suppressed below the
// fixed SPEC-023-owned k-anonymity floor. Aggregated only: no provider
// field. GET reads the snapshot; a missing or stale snapshot is
// `intake_unavailable` (503), never a partial count.

const (
	modelAdmissionIntakeSchema        = "model_admission_intake_offer_counts.v1"
	modelAdmissionIntakeWindow        = 30 * 24 * time.Hour
	modelAdmissionIntakeKAnonymityMin = 3
	modelAdmissionIntakeCadence       = 15 * time.Minute
	modelAdmissionIntakeStaleAfter    = 2 * modelAdmissionIntakeCadence
	modelAdmissionIntakeBuildTimeout  = 10 * time.Second
	modelAdmissionIntakeEventCeiling  = 100_000
)

var errModelAdmissionIntakeCeiling = errors.New("model admission intake: offer-event ceiling exceeded")

// ModelAdmissionIntakeRow is one `rows` element.
type ModelAdmissionIntakeRow struct {
	CatalogModelKey            string `json:"catalog_model_key"`
	DistinctProviderOfferCount *int   `json:"distinct_provider_offer_count"`
	Suppressed                 bool   `json:"suppressed"`
}

// modelAdmissionIntakeSnapshot is the materialized response.
type modelAdmissionIntakeSnapshot struct {
	generatedAt time.Time
	body        []byte
}

// modelAdmissionIntakeState is embedded in Server.
type modelAdmissionIntakeState struct {
	modelAdmissionIntakeMu sync.RWMutex
	modelAdmissionIntake   *modelAdmissionIntakeSnapshot
}

// BuildModelAdmissionIntakeRows applies the counting and suppression rules
// to offer events: a provider counts once per key it offered with a
// catalog_matched key; sanctioned providers are excluded (the predicate is
// evaluated once per provider at build time and an unreadable sanction
// source aborts the build); counts below k are reported as null +
// suppressed. Rows are ordered by key.
func BuildModelAdmissionIntakeRows(ctx context.Context, events []ModelAdmissionEvent, windowStart, windowEnd time.Time, sanctioned func(context.Context, string) (bool, error), k int) ([]ModelAdmissionIntakeRow, error) {
	providersByKey := map[string]map[string]struct{}{}
	sanctionCache := map[string]bool{}
	for _, event := range events {
		if event.State != modelAdmissionOfferSubmitted || event.CatalogModelKey == "" {
			continue
		}
		at := event.CreatedAt.UTC()
		if at.Before(windowStart) || at.After(windowEnd) {
			continue
		}
		isSanctioned, seen := sanctionCache[event.ProviderID]
		if !seen {
			if sanctioned != nil {
				var err error
				isSanctioned, err = sanctioned(ctx, event.ProviderID)
				if err != nil {
					return nil, fmt.Errorf("sanction source for provider: %w", err)
				}
			}
			sanctionCache[event.ProviderID] = isSanctioned
		}
		if isSanctioned {
			continue
		}
		set := providersByKey[event.CatalogModelKey]
		if set == nil {
			set = map[string]struct{}{}
			providersByKey[event.CatalogModelKey] = set
		}
		set[event.ProviderID] = struct{}{}
	}
	keys := make([]string, 0, len(providersByKey))
	for key := range providersByKey {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	rows := make([]ModelAdmissionIntakeRow, 0, len(keys))
	for _, key := range keys {
		n := len(providersByKey[key])
		if n < k {
			rows = append(rows, ModelAdmissionIntakeRow{CatalogModelKey: key, Suppressed: true})
			continue
		}
		count := n
		rows = append(rows, ModelAdmissionIntakeRow{CatalogModelKey: key, DistinctProviderOfferCount: &count})
	}
	return rows, nil
}

// providerIntakeSanctioned is the SPEC-047 v0.1.6 closed current-state
// `provider_intake_sanctioned(provider_id, at)` predicate, shared by the
// offer path and the intake aggregate:
//
//	(1) route        — SPEC-011 provisional admission `rejected`, or a
//	                   persisted SPEC-032 canary sanction with fail_count > 0;
//	(2) trust        — at least one hardware-trust root and none active;
//	(3) payout       — no per-provider payout sanction exists in v0.1.6;
//	(4) registration — a revoked SPEC-002 provider token and no active one.
//
// A sanction class the deployment does not operate (no trust store, no
// token issuer) contributes no sanction; a wired source that cannot be read
// returns an error, and callers fail closed on it.
func (s *Server) providerIntakeSanctioned(ctx context.Context, providerID string) (bool, error) {
	if s.admission != nil && s.admission.Rejected(providerID) {
		return true, nil
	}
	if s.pool != nil {
		for _, sanction := range s.pool.CanarySanctions() {
			if sanction.ProviderID == providerID && sanction.FailCount > 0 {
				return true, nil
			}
		}
	}
	if s.hardwareTrustAdmin != nil {
		sanctioned, err := s.hardwareTrustAdmin.ProviderHardwareTrustSanctioned(ctx, providerID)
		if err != nil {
			return false, fmt.Errorf("hardware trust: %w", err)
		}
		if sanctioned {
			return true, nil
		}
	}
	if s.issuer != nil {
		if history, ok := s.tokens.(providerTokenCustodyHistoryStore); ok && history != nil {
			revoked, err := history.HasRevokedTokenForProvider(ctx, providerID)
			if err != nil {
				return false, fmt.Errorf("token custody: %w", err)
			}
			if revoked {
				active, err := s.issuer.HasActiveTokenForProvider(ctx, providerID)
				if err != nil {
					return false, fmt.Errorf("token issuer: %w", err)
				}
				if !active {
					return true, nil
				}
			}
		}
	}
	return false, nil
}

// buildModelAdmissionIntakeSnapshot materializes the aggregate as one
// bounded job (SPEC-047 v0.1.6): a query timeout, an event ceiling, and
// every sanction source readable — otherwise no snapshot is produced and
// the previous one stays in place.
func (s *Server) buildModelAdmissionIntakeSnapshot(ctx context.Context) error {
	if s.modelAdmissions == nil {
		return errors.New("model admission store unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, modelAdmissionIntakeBuildTimeout)
	defer cancel()
	generatedAt := s.now().UTC().Truncate(time.Second)
	windowStart := generatedAt.Add(-modelAdmissionIntakeWindow)
	events, err := s.modelAdmissions.ModelAdmissionOfferEventsSince(ctx, windowStart)
	if err != nil {
		return fmt.Errorf("offer events: %w", err)
	}
	if len(events) > modelAdmissionIntakeEventCeiling {
		return errModelAdmissionIntakeCeiling
	}
	rows, err := BuildModelAdmissionIntakeRows(ctx, events, windowStart, generatedAt, s.providerIntakeSanctioned, modelAdmissionIntakeKAnonymityMin)
	if err != nil {
		return err
	}
	body, err := json.Marshal(map[string]any{
		"schema":          modelAdmissionIntakeSchema,
		"generated_at":    generatedAt.Format(time.RFC3339),
		"window_start":    windowStart.Format(time.RFC3339),
		"window_end":      generatedAt.Format(time.RFC3339),
		"k_anonymity_min": modelAdmissionIntakeKAnonymityMin,
		"rows":            rows,
	})
	if err != nil {
		return fmt.Errorf("encode: %w", err)
	}
	s.modelAdmissionIntakeMu.Lock()
	s.modelAdmissionIntake = &modelAdmissionIntakeSnapshot{generatedAt: generatedAt, body: body}
	s.modelAdmissionIntakeMu.Unlock()
	return nil
}

func (s *Server) runModelAdmissionIntakeLoop() {
	build := func() {
		if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
			s.log.Warn().Err(err).Msg("model admission intake snapshot build failed; previous snapshot retained")
		}
	}
	build()
	ticker := time.NewTicker(modelAdmissionIntakeCadence)
	defer ticker.Stop()
	for range ticker.C {
		build()
	}
}

// currentModelAdmissionIntake returns the snapshot when it exists and is
// not older than two cadences.
func (s *Server) currentModelAdmissionIntake() (*modelAdmissionIntakeSnapshot, bool) {
	s.modelAdmissionIntakeMu.RLock()
	snap := s.modelAdmissionIntake
	s.modelAdmissionIntakeMu.RUnlock()
	if snap == nil || s.now().UTC().Sub(snap.generatedAt) > modelAdmissionIntakeStaleAfter {
		return nil, false
	}
	return snap, true
}

func (s *Server) handleAdminModelAdmissionIntake(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "method not allowed"))
		return
	}
	if _, ok := s.authorizedModelAdmissionOperator(w, r); !ok {
		return
	}
	if len(r.URL.Query()) != 0 {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "no query parameters are accepted"))
		return
	}
	snap, ok := s.currentModelAdmissionIntake()
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("intake_unavailable", "model admission intake snapshot is unavailable"))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(snap.body)
}
