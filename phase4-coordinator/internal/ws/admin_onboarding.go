package ws

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
)

const defaultOnboardingListCap = providerevents.DefaultListPageCap

func (s *Server) handleAdminOnboarding(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.authStore == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "onboarding attempt store unavailable", "code": "onboarding_store_unavailable"}})
		return
	}
	filter := strings.TrimSpace(r.URL.Query().Get("state"))
	if filter != "" && filter != "all" && !auth.ValidOnboardingState(filter) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid state", "code": "invalid_request"}})
		return
	}
	limit := defaultOnboardingListCap
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid limit", "code": "invalid_request"}})
			return
		}
		limit = n
	}
	if limit > defaultOnboardingListCap {
		limit = defaultOnboardingListCap
	}
	afterID := strings.TrimSpace(r.URL.Query().Get("after"))
	afterTS := strings.TrimSpace(r.URL.Query().Get("after_ts"))
	if (afterID == "") != (afterTS == "") {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "after and after_ts must be supplied together", "code": "invalid_request"}})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	records, err := s.authStore.ListOnboardingAttempts(ctx)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "list onboarding attempts failed", "code": "onboarding_store_error"}})
		return
	}

	now := s.now().UTC()
	live := s.onboardingLivePresence()
	all := make([]auth.OnboardingAttempt, 0, len(records))
	for _, record := range records {
		if providerevents.LooksLikeCredential(record.ProviderID) {
			continue
		}
		presence, err := s.onboardingPresenceFor(ctx, record.ProviderID, live)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "onboarding presence lookup failed", "code": "events_store_error"}})
			return
		}
		all = append(all, auth.OverlayPresence(auth.AssembleOnboardingAttempt(record, now), presence, now, record))
	}

	summary := auth.SummarizeOnboardingAttempts(all)
	out, nextTS, nextID := auth.PageOnboardingAttempts(all, filter, limit, afterTS, afterID)
	resp := map[string]any{
		"attempts": out,
		"summary": map[string]any{
			"returned":       len(out),
			"pending":        summary.Pending,
			"confirmed":      summary.Confirmed,
			"live":           summary.Live,
			"failed_expired": summary.FailedExpired,
			"failed_revoked": summary.FailedRevoked,
			"limit":          limit,
		},
	}
	if nextID != "" {
		resp["next_after"] = nextID
		resp["next_after_ts"] = nextTS
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) onboardingLivePresence() map[string]struct{} {
	live := map[string]struct{}{}
	if s.pool == nil {
		return live
	}
	for _, p := range s.pool.Snapshot() {
		if s.isProviderTransportConnected(p) {
			live[p.ProviderID] = struct{}{}
		}
	}
	return live
}

func (s *Server) onboardingPresenceFor(ctx context.Context, providerID string, live map[string]struct{}) (auth.OnboardingPresence, error) {
	presence := auth.OnboardingPresence{}
	if _, ok := live[providerID]; ok {
		presence.Connected = true
		if p, ok := s.pool.Resolve(providerID, ""); ok {
			if !p.LastHeartbeatAt.IsZero() {
				presence.LastHeartbeatAt = p.LastHeartbeatAt.UTC().Format(time.RFC3339)
			}
			if !p.LastActivityAt.IsZero() {
				presence.LastSeenAt = p.LastActivityAt.UTC().Format(time.RFC3339)
			} else if !p.ConnectedAt.IsZero() {
				presence.LastSeenAt = p.ConnectedAt.UTC().Format(time.RFC3339)
			}
		}
	}
	if s.connectionEvents == nil {
		return presence, nil
	}
	snap, found, err := s.connectionEvents.GetLastKnown(ctx, providerID)
	if err != nil {
		return auth.OnboardingPresence{}, err
	}
	if found {
		if presence.LastSeenAt == "" && !snap.LastSeenAt.IsZero() {
			presence.LastSeenAt = snap.LastSeenAt.UTC().Format(time.RFC3339)
		}
		if presence.LastHeartbeatAt == "" && snap.LastHeartbeatAt != nil && !snap.LastHeartbeatAt.IsZero() {
			presence.LastHeartbeatAt = snap.LastHeartbeatAt.UTC().Format(time.RFC3339)
		}
	}
	ev, ok, err := s.connectionEvents.LatestEventProvider(ctx, providerID)
	if err != nil {
		return auth.OnboardingPresence{}, err
	}
	if ok {
		presence.LastEventKind = ev.Kind
		presence.LastEventOutcome = ev.Outcome
		presence.LastEventAt = ev.OccurredAt.UTC().Format(time.RFC3339)
		presence.LastFailureReason = ev.FailureReason
		if presence.LastSeenAt == "" && !ev.OccurredAt.IsZero() {
			presence.LastSeenAt = ev.OccurredAt.UTC().Format(time.RFC3339)
		}
	}
	return presence, nil
}
