package stats

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

// Handler is the SPEC-017 §5 handler bundle. Owned by the
// `stats_reader` `*sql.DB` injection. Mounted from
// cmd/coordinator/main.go on both coordinator.streamvc.live
// and stats.streamvc.live via the same binary.
type Handler struct {
	Store        *store.Store
	CORS         CORSConfig
	BackfillMode string
	PartialSince string // RFC 3339 timestamp; empty = Path B
	Now          func() time.Time
}

// nowFn returns the handler's time source, defaulting to
// time.Now if the embedding caller did not inject a test fake.
func (h *Handler) nowFn() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now().UTC()
}

// ===========================================================================
// §5.1 /v1/stats/overview
// ===========================================================================

type overviewResponse struct {
	GeneratedAt string             `json:"generated_at"`
	Network     overviewNetwork    `json:"network"`
	Timeseries  overviewTimeseries `json:"timeseries"`
	Meta        overviewMeta       `json:"meta"`
}

type overviewNetwork struct {
	NodesOnline           int     `json:"nodes_online"`
	NodesHardwareAttested int     `json:"nodes_hardware_attested"`
	BandwidthGBPerSec     int64   `json:"bandwidth_gb_per_s"`
	NetworkPowerKW        float64 `json:"network_power_kw"`
	NetworkUtilizationPct int     `json:"network_utilization_pct"`
	GPUCoresTotal         int     `json:"gpu_cores_total"`
	CPUCoresTotal         int     `json:"cpu_cores_total"`
	UnifiedRAMGBTotal     int     `json:"unified_ram_gb_total"`
	ModelsServing         int     `json:"models_serving"`
	TokensInTotal         int64   `json:"tokens_in_total"`
	TokensOutTotal        int64   `json:"tokens_out_total"`
	RequestsTotal         int64   `json:"requests_total"`
}

type overviewTimeseries struct {
	// Each is a 30-element array. Missing minutes render as
	// JSON `null` per §5.1 — encoded as `*int64` with nil
	// pointer per slot.
	RpmRequests     []*int64 `json:"rpm_requests"`
	TpmInputTokens  []*int64 `json:"tpm_input_tokens"`
	TpmOutputTokens []*int64 `json:"tpm_output_tokens"`
}

type overviewMeta struct {
	WindowSeconds int `json:"window_seconds"`
}

func (h *Handler) handleOverview(w http.ResponseWriter, r *http.Request, ar authResult) {
	ctx := r.Context()
	now := h.nowFn()

	ov, err := h.Store.Overview(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "overview read failed")
		return
	}
	if ov == nil || overviewStaleFor503(now, ov.GeneratedAt) {
		// AC-14: 503 stale path. MUST be emitted AFTER cheap
		// auth/CORS validation (already done) BUT BEFORE the
		// post-auth success rate-limit debit (a rollup outage
		// MUST NOT exhaust client quotas). The mux wraps this
		// branch so the post-auth limiter sees a 503 sentinel.
		w.Header().Set("Retry-After", "30")
		writeError(w, http.StatusServiceUnavailable, codeStatsStale, "overview is stale")
		return
	}

	rpm, err := h.Store.RpmTimeseries(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "rpm read failed")
		return
	}
	tpm, err := h.Store.TpmTimeseries(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "tpm read failed")
		return
	}

	resp := overviewResponse{
		GeneratedAt: ov.GeneratedAt.UTC().Format(time.RFC3339),
		Network: overviewNetwork{
			NodesOnline:           ov.NodesOnline,
			NodesHardwareAttested: ov.NodesHardwareAttested,
			BandwidthGBPerSec:     ov.BandwidthGBPerSec,
			NetworkPowerKW:        ov.NetworkPowerKW,
			NetworkUtilizationPct: ov.NetworkUtilizationPct,
			GPUCoresTotal:         ov.GPUCoresTotal,
			CPUCoresTotal:         ov.CPUCoresTotal,
			UnifiedRAMGBTotal:     ov.UnifiedRAMGBTotal,
			ModelsServing:         ov.ModelsServing,
			TokensInTotal:         ov.TokensIn,
			TokensOutTotal:        ov.TokensOut,
			RequestsTotal:         ov.Requests,
		},
		Timeseries: overviewTimeseries{
			RpmRequests:     alignRpm30(rpm, now),
			TpmInputTokens:  alignTpm30(tpm, now, func(t store.TimeseriesRow) int64 { return t.InTok }),
			TpmOutputTokens: alignTpm30(tpm, now, func(t store.TimeseriesRow) int64 { return t.OutTok }),
		},
		Meta: overviewMeta{WindowSeconds: 30 * 60},
	}

	writeJSON(w, r, http.StatusOK, resp, ov.GeneratedAt,
		"public, max-age=30, s-maxage=30, stale-while-revalidate=60",
		varyForPublic(),
		ar)
}

// alignRpm30 builds the 30-element JSON-shaped array (one slot
// per minute over the rolling 30 minutes ending at `now`),
// emitting `nil` (= JSON null) for absent minutes per §5.1.
func alignRpm30(rows []store.TimeseriesRow, now time.Time) []*int64 {
	out := make([]*int64, 30)
	end := now.Truncate(time.Minute)
	start := end.Add(-30 * time.Minute)
	byMin := make(map[int64]int64, len(rows))
	for _, r := range rows {
		byMin[r.Bucket.Truncate(time.Minute).Unix()] = r.Value
	}
	for i := 0; i < 30; i++ {
		bucket := start.Add(time.Duration(i) * time.Minute)
		if v, ok := byMin[bucket.Unix()]; ok {
			vv := v
			out[i] = &vv
		}
	}
	return out
}

func alignTpm30(rows []store.TimeseriesRow, now time.Time, pick func(store.TimeseriesRow) int64) []*int64 {
	out := make([]*int64, 30)
	end := now.Truncate(time.Minute)
	start := end.Add(-30 * time.Minute)
	byMin := make(map[int64]int64, len(rows))
	for _, r := range rows {
		byMin[r.Bucket.Truncate(time.Minute).Unix()] = pick(r)
	}
	for i := 0; i < 30; i++ {
		bucket := start.Add(time.Duration(i) * time.Minute)
		if v, ok := byMin[bucket.Unix()]; ok {
			vv := v
			out[i] = &vv
		}
	}
	return out
}

// ===========================================================================
// §5.2 /v1/stats/leaderboard
// ===========================================================================

type leaderboardResponse struct {
	GeneratedAt         string                `json:"generated_at"`
	Window              string                `json:"window"`
	Sort                string                `json:"sort"`
	Rows                []leaderboardRespRow  `json:"rows"`
	Totals              leaderboardTotalsResp `json:"totals"`
	Meta                leaderboardMeta       `json:"meta"`
	PartialHistorySince string                `json:"partial_history_since,omitempty"`
}

type leaderboardRespRow struct {
	Pseudonym      string  `json:"pseudonym"`
	RankEarnings   int     `json:"rank_earnings"`
	RankTokens     int     `json:"rank_tokens"`
	RankJobs       int     `json:"rank_jobs"`
	EarningsBucket string  `json:"earnings_bucket"`
	ExactEarnings  *string `json:"exact_earnings"` // nil = JSON null
	Tokens         int64   `json:"tokens"`
	Jobs           int64   `json:"jobs"`
	// Partner-only fields. omitempty so the public projection
	// emits NEITHER an empty string nor the key.
	EarningsUSD        string `json:"earnings_usd,omitempty"`
	EarningsWorkUSD    string `json:"earnings_work_usd,omitempty"`
	EarningsRewardsUSD string `json:"earnings_rewards_usd,omitempty"`
	FirstSeenAt        string `json:"first_seen_at,omitempty"`
	LastSeenAt         string `json:"last_seen_at,omitempty"`
}

type leaderboardTotalsResp struct {
	ActiveAccounts int64 `json:"active_accounts"`
	Tokens         int64 `json:"tokens"`
	Jobs           int64 `json:"jobs"`
	// Partner-only totals.
	EarningsUSD        string `json:"earnings_usd,omitempty"`
	EarningsWorkUSD    string `json:"earnings_work_usd,omitempty"`
	EarningsRewardsUSD string `json:"earnings_rewards_usd,omitempty"`
}

type leaderboardMeta struct {
	RewardsPopulated bool `json:"rewards_populated"`
}

func (h *Handler) handleLeaderboard(w http.ResponseWriter, r *http.Request, ar authResult) {
	ctx := r.Context()
	now := h.nowFn()

	window := r.URL.Query().Get("window")
	if window == "" {
		window = "24h"
	}
	switch window {
	case "24h", "7d", "30d", "all":
	default:
		writeError(w, http.StatusBadRequest, codeBadRequest, "invalid window")
		return
	}

	sort := r.URL.Query().Get("sort")
	if sort == "" {
		sort = "earnings"
	}
	switch sort {
	case "earnings", "tokens", "jobs":
	default:
		writeError(w, http.StatusBadRequest, codeBadRequest, "invalid sort")
		return
	}

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 100 {
			writeError(w, http.StatusBadRequest, codeBadRequest, "invalid limit")
			return
		}
		limit = n
	}

	rows, err := h.Store.Leaderboard(ctx, window, sort, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "leaderboard read failed")
		return
	}
	totals, err := h.Store.LeaderboardTotals(ctx, window)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "leaderboard totals read failed")
		return
	}
	rewardsPop, err := h.Store.RewardsPopulated(ctx, window)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "rewards_populated read failed")
		return
	}

	partnerProj := ar.projection == "partner"

	respRows := make([]leaderboardRespRow, 0, len(rows))
	for _, r := range rows {
		row := leaderboardRespRow{
			Pseudonym:      r.Pseudonym,
			RankEarnings:   r.RankEarnings,
			RankTokens:     r.RankTokens,
			RankJobs:       r.RankJobs,
			EarningsBucket: r.Bucket,
			Tokens:         r.Tokens,
			Jobs:           r.Jobs,
		}
		// Public projection: exact_earnings populated iff
		// visibility.mode = "exact"; otherwise null (default
		// bucketed per AC-19 + §6.1 left-join semantics).
		if r.VisibilityMode == "exact" {
			v := r.EarningsTotalUSD
			row.ExactEarnings = &v
		} else {
			row.ExactEarnings = nil
		}
		if partnerProj {
			row.EarningsUSD = r.EarningsTotalUSD
			row.EarningsWorkUSD = r.EarningsWorkUSD
			row.EarningsRewardsUSD = r.EarningsRewardsUSD
			if r.FirstSeenAt.Valid {
				row.FirstSeenAt = r.FirstSeenAt.Time.UTC().Format(time.RFC3339)
			}
			if r.LastSeenAt.Valid {
				row.LastSeenAt = r.LastSeenAt.Time.UTC().Format(time.RFC3339)
			}
		}
		respRows = append(respRows, row)
	}

	tot := leaderboardTotalsResp{
		ActiveAccounts: totals.ActiveAccounts,
		Tokens:         totals.Tokens,
		Jobs:           totals.Jobs,
	}
	if partnerProj {
		tot.EarningsUSD = totals.EarningsUSD
		tot.EarningsWorkUSD = totals.EarningsWork
		tot.EarningsRewardsUSD = totals.EarningsReward
	}

	resp := leaderboardResponse{
		GeneratedAt: totals.GeneratedAt.UTC().Format(time.RFC3339),
		Window:      window,
		Sort:        sort,
		Rows:        respRows,
		Totals:      tot,
		Meta:        leaderboardMeta{RewardsPopulated: rewardsPop},
	}

	// partial_history_since exposed iff (config non-empty AND
	// window is 30d or all AND now - since < window length).
	if h.shouldExposePartialHistorySince(window, now) {
		resp.PartialHistorySince = h.PartialSince
	}

	cacheControl := "public, max-age=60, s-maxage=60, stale-while-revalidate=120"
	vary := varyForPublic()
	if partnerProj {
		cacheControl = "private, max-age=30, s-maxage=30"
		vary = varyForPartner()
	}

	writeJSON(w, r, http.StatusOK, resp, totals.GeneratedAt, cacheControl, vary, ar)
}

func (h *Handler) shouldExposePartialHistorySince(window string, now time.Time) bool {
	if h.PartialSince == "" {
		return false
	}
	if window != "30d" && window != "all" {
		return false
	}
	t, err := time.Parse(time.RFC3339, h.PartialSince)
	if err != nil {
		return false
	}
	var winLen time.Duration
	switch window {
	case "30d":
		winLen = 30 * 24 * time.Hour
	case "all":
		// 'all' is open-ended; expose the field iff the rollup
		// has not yet overlapped its window by the all-window
		// proxy (1 year — operator MAY revisit). The locked
		// SPEC §9.7 wording is "less than the window length";
		// for "all" we approximate as 365d.
		winLen = 365 * 24 * time.Hour
	}
	return now.Sub(t) < winLen
}

// ===========================================================================
// §5.3 /v1/stats/health
// ===========================================================================

type healthResponse struct {
	GeneratedAt string                     `json:"generated_at"`
	Status      string                     `json:"status"`
	Components  map[string]healthComponent `json:"components"`
}

type healthComponent struct {
	Status      string `json:"status"`
	GeneratedAt string `json:"generated_at"`
	LastErrorAt string `json:"last_error_at,omitempty"`
}

func (h *Handler) handleHealth(w http.ResponseWriter, r *http.Request, ar authResult) {
	ctx := r.Context()
	now := h.nowFn()

	comps, err := h.Store.ComponentsHealth(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "health read failed")
		return
	}
	compMap := make(map[string]healthComponent, len(comps))
	overall := "ok"
	for _, c := range comps {
		s := statusFromFreshness(now, c.GeneratedAt, c.Component)
		entry := healthComponent{
			Status:      s,
			GeneratedAt: c.GeneratedAt.UTC().Format(time.RFC3339),
		}
		if c.LastErrorAt.Valid {
			entry.LastErrorAt = c.LastErrorAt.Time.UTC().Format(time.RFC3339)
		}
		compMap[c.Component] = entry
		// Aggregate worst-case.
		if rank(s) > rank(overall) {
			overall = s
		}
	}

	resp := healthResponse{
		GeneratedAt: now.Format(time.RFC3339),
		Status:      overall,
		Components:  compMap,
	}
	// /v1/stats/health returns 200 even when degraded/down
	// per §5.3. Use the request `now` as the generated-at for
	// the X-Stats-Generated-At header.
	writeJSON(w, r, http.StatusOK, resp, now,
		"public, max-age=10, s-maxage=10", varyForPublic(), ar)
}

func rank(s string) int {
	switch s {
	case "down":
		return 2
	case "degraded":
		return 1
	}
	return 0
}

// ===========================================================================
// Shared response writer
// ===========================================================================

// writeJSON serializes `body`, computes the weak ETag,
// handles 304, emits the §5.2/§5.7 CORS headers per
// projection, the per-endpoint Vary, the per-endpoint
// Cache-Control, and X-Stats-Generated-At (on non-304).
// HEAD requests reach this with the same arguments; the
// function emits the same headers + no body.
func writeJSON(w http.ResponseWriter, r *http.Request, status int, body any, generatedAt time.Time, cacheControl, vary string, ar authResult) {
	buf, err := json.Marshal(body)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "marshal failed")
		return
	}
	etag := weakETag(buf)
	if ifNoneMatchEquals(r.Header.Get("If-None-Match"), etag) {
		// 304 carries only RFC 7232 headers per §5.9. No body,
		// no X-Stats-Generated-At.
		w.Header().Set("ETag", etag)
		w.Header().Set("Cache-Control", cacheControl)
		w.Header().Set("Vary", vary)
		w.WriteHeader(http.StatusNotModified)
		return
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", cacheControl)
	w.Header().Set("Vary", vary)
	w.Header().Set("X-Stats-Generated-At", generatedAt.UTC().Format(time.RFC3339))
	writeCORSHeaders(w, ar.projection == "partner", ar.originPresent, ar.originValue)

	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(buf)
}

func varyForPublic() string  { return "Accept-Encoding, Origin" }
func varyForPartner() string { return "Accept-Encoding, Origin, Authorization" }

// Ensure context import isn't elided in builds where the
// handler body trims further.
var _ = context.Background

// trimEndpointFromPath returns the route token Step 3 keys the
// per-endpoint rate-limit buckets on. Returns one of
// "overview", "leaderboard", "health" or "" for paths outside
// the /v1/stats/* subtree.
func trimEndpointFromPath(p string) string {
	const prefix = "/v1/stats/"
	if !strings.HasPrefix(p, prefix) {
		return ""
	}
	rest := p[len(prefix):]
	if i := strings.Index(rest, "/"); i >= 0 {
		rest = rest[:i]
	}
	switch rest {
	case "overview", "leaderboard", "health":
		return rest
	}
	return ""
}
