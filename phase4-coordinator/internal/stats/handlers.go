package stats

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
	"github.com/rs/zerolog"
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
	Logger       zerolog.Logger

	idlePrewarmRead func(context.Context, string) (store.ProviderIdlePrewarmSummary, error)
}

const providerIdlePrewarmReadTimeout = 250 * time.Millisecond

// nowFn returns the handler's time source, defaulting to
// time.Now if the embedding caller did not inject a test fake.
func (h *Handler) nowFn() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now().UTC()
}

// overviewStaleProbe peeks at `stats_overview_current.generated_at`
// for the §5.8 503 budget check. Called by the mux BEFORE the
// post-auth success bucket debit so stale 503 responses do not
// exhaust client quotas (round-1 ARCH C1 fix). Returns
// (stale, snapshotGen, err).
func (h *Handler) overviewStaleProbe(ctx context.Context, now time.Time) (bool, time.Time, error) {
	ov, err := h.Store.Overview(ctx)
	if err != nil {
		return false, time.Time{}, err
	}
	if ov == nil {
		return true, time.Time{}, nil
	}
	return overviewStaleFor503(now, ov.GeneratedAt), ov.GeneratedAt, nil
}

// ===========================================================================
// §5.1 /v1/stats/overview
// ===========================================================================

// overviewResponse mirrors the locked §5.1 wire shape:
//
//	{ generated_at, stale_after, network{14 fields},
//	  timeseries{rpm_30m{bucket_seconds, points[]},
//	             tpm_30m{bucket_seconds, points[]}} }
type overviewResponse struct {
	GeneratedAt string                     `json:"generated_at"`
	StaleAfter  string                     `json:"stale_after"`
	Network     overviewNetwork            `json:"network"`
	Timeseries  overviewTimeseries         `json:"timeseries"`
	IdlePrewarm overviewIdlePrewarmSummary `json:"idle_prewarm"`
}

// overviewNetwork is the §5.1.1 14-field schema (12 distinct
// counters + 2 derived: tokens_served_total and
// avg_tokens_per_request).
type overviewNetwork struct {
	TokensServedTotal     int64   `json:"tokens_served_total"`
	TokensInTotal         int64   `json:"tokens_in_total"`
	TokensOutTotal        int64   `json:"tokens_out_total"`
	RequestsTotal         int64   `json:"requests_total"`
	NodesOnline           int     `json:"nodes_online"`
	NodesHardwareAttested int     `json:"nodes_hardware_attested"`
	BandwidthGBPerSec     int64   `json:"bandwidth_gb_per_s"`
	NetworkPowerKW        float64 `json:"network_power_kw"`
	NetworkUtilizationPct int     `json:"network_utilization_pct"`
	GPUCoresTotal         int     `json:"gpu_cores_total"`
	CPUCoresTotal         int     `json:"cpu_cores_total"`
	UnifiedRAMGBTotal     int     `json:"unified_ram_gb_total"`
	AvgTokensPerRequest   int64   `json:"avg_tokens_per_request"`
	ModelsServing         int     `json:"models_serving"`
}

type overviewTimeseries struct {
	Rpm30m timeseriesRpm `json:"rpm_30m"`
	Tpm30m timeseriesTpm `json:"tpm_30m"`
}

type overviewIdlePrewarmSummary struct {
	PoolPctWithB1Active int              `json:"pool_pct_with_b1_active"`
	SkipsByReasonLast1h map[string]int64 `json:"skips_by_reason_last_1h"`
}

type providerIdlePrewarmResponse struct {
	EventsLast1h        map[string]int64 `json:"events_last_1h"`
	SkipsByReasonLast1h map[string]int64 `json:"skips_by_reason_last_1h"`
}

type timeseriesRpm struct {
	BucketSeconds int        `json:"bucket_seconds"`
	Points        []rpmPoint `json:"points"`
}

// rpmPoint emits {"t": "...", "value": N|null}. Value uses
// *int64 so JSON null distinguishes "no data" from "zero
// traffic" per §5.1.
type rpmPoint struct {
	T     string `json:"t"`
	Value *int64 `json:"value"`
}

type timeseriesTpm struct {
	BucketSeconds int        `json:"bucket_seconds"`
	Points        []tpmPoint `json:"points"`
}

type tpmPoint struct {
	T            string `json:"t"`
	InputTokens  *int64 `json:"input_tokens"`
	OutputTokens *int64 `json:"output_tokens"`
}

// handleOverview implements §5.1.
//
// The stale-503 check has already passed in the mux's
// freshness-before-debit pre-check; this handler can assume the
// overview snapshot is within the §5.8 120s budget.
func (h *Handler) handleOverview(w http.ResponseWriter, r *http.Request, ar authResult) {
	ctx := r.Context()
	now := h.nowFn()

	ov, err := h.Store.Overview(ctx)
	if err != nil || ov == nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "overview read failed", now, nil)
		return
	}

	rpm, err := h.Store.RpmTimeseries(ctx)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "rpm read failed", now, nil)
		return
	}
	tpm, err := h.Store.TpmTimeseries(ctx)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "tpm read failed", now, nil)
		return
	}

	// Step 4.C observability tap — record snapshot freshness
	// for the access-log middleware to emit on stats_request_served.
	if obs := requestObsFromContext(r.Context()); obs != nil {
		obs.GeneratedAtAgeMs = time.Since(ov.GeneratedAt).Milliseconds()
	}

	tokensServed := ov.TokensIn + ov.TokensOut
	avgTokensPerRequest := int64(0)
	if ov.Requests > 0 {
		avgTokensPerRequest = tokensServed / ov.Requests
	}

	resp := overviewResponse{
		GeneratedAt: ov.GeneratedAt.UTC().Format(time.RFC3339),
		StaleAfter:  ov.GeneratedAt.Add(30 * time.Second).UTC().Format(time.RFC3339),
		Network: overviewNetwork{
			TokensServedTotal:     tokensServed,
			TokensInTotal:         ov.TokensIn,
			TokensOutTotal:        ov.TokensOut,
			RequestsTotal:         ov.Requests,
			NodesOnline:           ov.NodesOnline,
			NodesHardwareAttested: ov.NodesHardwareAttested,
			BandwidthGBPerSec:     ov.BandwidthGBPerSec,
			NetworkPowerKW:        ov.NetworkPowerKW,
			NetworkUtilizationPct: ov.NetworkUtilizationPct,
			GPUCoresTotal:         ov.GPUCoresTotal,
			CPUCoresTotal:         ov.CPUCoresTotal,
			UnifiedRAMGBTotal:     ov.UnifiedRAMGBTotal,
			AvgTokensPerRequest:   avgTokensPerRequest,
			ModelsServing:         ov.ModelsServing,
		},
		Timeseries: overviewTimeseries{
			Rpm30m: timeseriesRpm{
				BucketSeconds: 60,
				// Round-2 ARCH C1 / CODE H4 fix: align points
				// to the snapshot, NOT request time. The ETag
				// is sha256(body); a request-time anchor would
				// shift bucket timestamps every minute and
				// produce a different ETag without a snapshot
				// advance. SPEC §5.1 locks ETag as "computed
				// once per rollup snapshot and reused until
				// generated_at advances."
				Points: alignRpmPoints(rpm, ov.GeneratedAt),
			},
			Tpm30m: timeseriesTpm{
				BucketSeconds: 60,
				Points:        alignTpmPoints(tpm, ov.GeneratedAt),
			},
		},
		IdlePrewarm: overviewIdlePrewarmSummary{
			PoolPctWithB1Active: ov.IdlePrewarm.PoolPctWithB1Active,
			SkipsByReasonLast1h: decodeReasonCounts(ov.IdlePrewarm.SkipsByReasonLast1hJSON),
		},
	}

	writeJSON(w, r, http.StatusOK, resp, ov.GeneratedAt,
		"public, max-age=30, s-maxage=30, stale-while-revalidate=60",
		varyForPublic(),
		ar)
}

// alignRpmPoints builds the 30-element timestamped points array
// per §5.1 — one per minute over the rolling 30 minutes ending
// at now-1m. Missing minutes render as JSON null per §5.1 (the
// pointer is nil; encoding/json emits `"value": null`).
// alignRpmPoints anchors the 30-element grid to `anchor`, which
// MUST be the snapshot timestamp (NOT request time). The grid
// ends at anchor.Truncate(minute) and runs 30 minutes back.
func alignRpmPoints(rows []store.TimeseriesRow, anchor time.Time) []rpmPoint {
	out := make([]rpmPoint, 30)
	end := anchor.Truncate(time.Minute)
	start := end.Add(-30 * time.Minute)
	byMin := make(map[int64]int64, len(rows))
	for _, r := range rows {
		byMin[r.Bucket.Truncate(time.Minute).Unix()] = r.Value
	}
	for i := 0; i < 30; i++ {
		bucket := start.Add(time.Duration(i) * time.Minute)
		p := rpmPoint{T: bucket.UTC().Format(time.RFC3339)}
		if v, ok := byMin[bucket.Unix()]; ok {
			vv := v
			p.Value = &vv
		}
		out[i] = p
	}
	return out
}

func alignTpmPoints(rows []store.TimeseriesRow, anchor time.Time) []tpmPoint {
	out := make([]tpmPoint, 30)
	end := anchor.Truncate(time.Minute)
	start := end.Add(-30 * time.Minute)
	type pair struct{ in, out int64 }
	byMin := make(map[int64]pair, len(rows))
	for _, r := range rows {
		byMin[r.Bucket.Truncate(time.Minute).Unix()] = pair{r.InTok, r.OutTok}
	}
	for i := 0; i < 30; i++ {
		bucket := start.Add(time.Duration(i) * time.Minute)
		p := tpmPoint{T: bucket.UTC().Format(time.RFC3339)}
		if v, ok := byMin[bucket.Unix()]; ok {
			in := v.in
			outV := v.out
			p.InputTokens = &in
			p.OutputTokens = &outV
		}
		out[i] = p
	}
	return out
}

// ===========================================================================
// §5.2 /v1/stats/leaderboard
// ===========================================================================

type leaderboardResponse struct {
	GeneratedAt         string                `json:"generated_at"`
	StaleAfter          string                `json:"stale_after"`
	Window              string                `json:"window"`
	Sort                string                `json:"sort"`
	Limit               int                   `json:"limit"`
	PartialHistorySince string                `json:"partial_history_since,omitempty"`
	Meta                leaderboardMeta       `json:"meta"`
	Totals              leaderboardTotalsResp `json:"totals"`
	Rows                []leaderboardRespRow  `json:"rows"`
}

type providerStatsResponse struct {
	GeneratedAt string                      `json:"generated_at"`
	StaleAfter  string                      `json:"stale_after"`
	Window      string                      `json:"window"`
	ProviderID  string                      `json:"provider_id"`
	Row         leaderboardRespRow          `json:"row"`
	IdlePrewarm providerIdlePrewarmResponse `json:"idle_prewarm"`
}

type leaderboardMeta struct {
	RewardsPopulated bool `json:"rewards_populated"`
}

// leaderboardRespRow is the §5.2 wire shape. `rank` is the
// single per-axis rank (not three rank_* fields per the
// round-1 audit). USD fields are JSON numbers (float64).
//
// The partner projection adds earnings_usd / earnings_work_usd
// / earnings_rewards_usd / first_seen_at / last_seen_at. The
// public projection sets `ExactEarnings` from the
// total-earnings string iff visibility.mode = "exact".
type leaderboardRespRow struct {
	Rank           int    `json:"rank"`
	Pseudonym      string `json:"pseudonym"`
	EarningsBucket string `json:"earnings_bucket"`
	Tokens         int64  `json:"tokens"`
	Jobs           int64  `json:"jobs"`
	// ExactEarnings is always present in JSON; null in the
	// public projection unless visibility.mode = "exact".
	ExactEarnings *float64 `json:"exact_earnings"`
	// Partner-only — omitempty so public projection omits.
	EarningsUSD        *float64 `json:"earnings_usd,omitempty"`
	EarningsWorkUSD    *float64 `json:"earnings_work_usd,omitempty"`
	EarningsRewardsUSD *float64 `json:"earnings_rewards_usd,omitempty"`
	FirstSeenAt        string   `json:"first_seen_at,omitempty"`
	LastSeenAt         string   `json:"last_seen_at,omitempty"`
}

type leaderboardTotalsResp struct {
	Tokens         int64 `json:"tokens"`
	Jobs           int64 `json:"jobs"`
	ActiveAccounts int64 `json:"active_accounts"`
	// Partner-only totals.
	EarningsUSD        *float64 `json:"earnings_usd,omitempty"`
	EarningsWorkUSD    *float64 `json:"earnings_work_usd,omitempty"`
	EarningsRewardsUSD *float64 `json:"earnings_rewards_usd,omitempty"`
}

// leaderboardStaleBudgetSeconds returns the §9.5 503 budget
// (in seconds) for the requested window. 24h→300, 7d→1800,
// 30d→14400, all→86400.
func leaderboardStaleBudgetSeconds(window string) int {
	switch window {
	case "24h":
		return 300
	case "7d":
		return 1800
	case "30d":
		return 14400
	case "all":
		return 86400
	}
	return 300
}

// leaderboardSMaxAgeSeconds returns the per-projection s-maxage
// the `stale_after` field is derived from. Public projection
// caches for 60s; partner projection for 30s per §5.2.
func leaderboardSMaxAgeSeconds(partner bool) int {
	if partner {
		return 30
	}
	return 60
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
		writeError(w, r, http.StatusBadRequest, codeBadRequest, "invalid window", now, nil)
		return
	}

	sort := r.URL.Query().Get("sort")
	if sort == "" {
		sort = "earnings"
	}
	switch sort {
	case "earnings", "tokens", "jobs":
	default:
		writeError(w, r, http.StatusBadRequest, codeBadRequest, "invalid sort", now, nil)
		return
	}

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 100 {
			writeError(w, r, http.StatusBadRequest, codeBadRequest, "invalid limit", now, nil)
			return
		}
		limit = n
	}

	partnerProj := ar.projection == "partner"
	if partnerProj && ar.matchedKey != nil && ar.matchedKey.ProviderID.Valid {
		writeError(w, r, http.StatusForbidden, codeUnauthorized, "unauthorized", now, nil)
		return
	}

	rows, err := h.Store.Leaderboard(ctx, window, sort, limit)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "leaderboard read failed", now, nil)
		return
	}

	// §5.8 per-window staleness check — leaderboard's
	// generated_at is the snapshot tick time (consistent across
	// every row in a single tick). Round-2 ARCH H1 / CODE H3
	// fix: when the leaderboard table is empty, read
	// stats_components_health.leaderboard_<window>.generated_at
	// as the snapshot timestamp; empty + valid snapshot is a
	// legitimate empty page, but a missing/epoch snapshot is
	// a 503.
	var snapshotTime time.Time
	if len(rows) > 0 {
		snapshotTime = rows[0].GeneratedAt
	} else {
		gen, gerr := h.Store.ComponentGeneratedAt(ctx, "leaderboard_"+window)
		if gerr != nil {
			writeError(w, r, http.StatusInternalServerError, codeInternal, "components_health read failed", now, nil)
			return
		}
		snapshotTime = gen
	}
	if snapshotTime.IsZero() {
		retry := 30
		writeError(w, r, http.StatusServiceUnavailable, codeStatsStale, "leaderboard is stale", now, &retry)
		return
	}
	if h.leaderboardStaleFor503(snapshotTime, now, window) {
		retry := 30
		writeError(w, r, http.StatusServiceUnavailable, codeStatsStale, "leaderboard is stale", now, &retry)
		return
	}

	// Step 4.C observability tap (post-freshness check so we
	// only record age for the response we actually return).
	if obs := requestObsFromContext(r.Context()); obs != nil {
		obs.GeneratedAtAgeMs = time.Since(snapshotTime).Milliseconds()
	}

	rewardsPop, err := h.Store.RewardsPopulated(ctx, window)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "rewards_populated read failed", now, nil)
		return
	}

	respRows := make([]leaderboardRespRow, 0, len(rows))
	// Page-scoped sums for totals (round-1 ARCH H2 fix: totals
	// scoped to the returned page, NOT the whole table).
	var pageTokens, pageJobs int64
	var pageEarn, pageEarnWork, pageEarnReward float64
	distinct := make(map[string]struct{}, len(rows))
	for _, r := range rows {
		rank := r.RankEarnings
		if sort == "tokens" {
			rank = r.RankTokens
		} else if sort == "jobs" {
			rank = r.RankJobs
		}
		row := leaderboardRespRow{
			Rank:           rank,
			Pseudonym:      r.Pseudonym,
			EarningsBucket: r.Bucket,
			Tokens:         r.Tokens,
			Jobs:           r.Jobs,
		}
		earn := parseUSD(r.EarningsTotalUSD)
		work := parseUSD(r.EarningsWorkUSD)
		reward := parseUSD(r.EarningsRewardsUSD)
		// Public projection: exact_earnings populated iff
		// visibility.mode = "exact"; otherwise null (default
		// bucketed per AC-19 + §6.1 left-join semantics).
		if r.VisibilityMode == "exact" {
			v := earn
			row.ExactEarnings = &v
		} else {
			row.ExactEarnings = nil
		}
		if partnerProj {
			earnCopy := earn
			workCopy := work
			rewardCopy := reward
			row.EarningsUSD = &earnCopy
			row.EarningsWorkUSD = &workCopy
			row.EarningsRewardsUSD = &rewardCopy
			if r.FirstSeenAt.Valid {
				row.FirstSeenAt = r.FirstSeenAt.Time.UTC().Format(time.RFC3339)
			}
			if r.LastSeenAt.Valid {
				row.LastSeenAt = r.LastSeenAt.Time.UTC().Format(time.RFC3339)
			}
		}
		respRows = append(respRows, row)
		pageTokens += r.Tokens
		pageJobs += r.Jobs
		if r.Jobs >= 1 {
			distinct[r.ProviderID] = struct{}{}
		}
		pageEarn += earn
		pageEarnWork += work
		pageEarnReward += reward
	}

	tot := leaderboardTotalsResp{
		Tokens:         pageTokens,
		Jobs:           pageJobs,
		ActiveAccounts: int64(len(distinct)),
	}
	if partnerProj {
		e := round2(pageEarn)
		ew := round2(pageEarnWork)
		er := round2(pageEarnReward)
		tot.EarningsUSD = &e
		tot.EarningsWorkUSD = &ew
		tot.EarningsRewardsUSD = &er
	}

	cacheControl := "public, max-age=60, s-maxage=60, stale-while-revalidate=120"
	vary := varyForPublic()
	if partnerProj {
		cacheControl = "private, max-age=30, s-maxage=30"
		vary = varyForPartner()
		w.Header().Set("Deprecation", "@1783296000")
		w.Header().Add("Link", `</v1/stats/provider/{provider_id}>; rel="deprecation"`)
		w.Header().Set("Warning", `299 - "Deprecated partner leaderboard projection; use /v1/stats/provider/{provider_id}"`)
	}

	smax := leaderboardSMaxAgeSeconds(partnerProj)
	resp := leaderboardResponse{
		GeneratedAt: snapshotTime.UTC().Format(time.RFC3339),
		StaleAfter:  snapshotTime.Add(time.Duration(smax) * time.Second).UTC().Format(time.RFC3339),
		Window:      window,
		Sort:        sort,
		Limit:       limit,
		Meta:        leaderboardMeta{RewardsPopulated: rewardsPop},
		Totals:      tot,
		Rows:        respRows,
	}

	// partial_history_since exposed iff (config non-empty AND
	// window is 30d or all AND now - since < window length).
	if h.shouldExposePartialHistorySince(window, now) {
		resp.PartialHistorySince = h.PartialSince
	}

	writeJSON(w, r, http.StatusOK, resp, snapshotTime, cacheControl, vary, ar)
}

func (h *Handler) handleProvider(w http.ResponseWriter, r *http.Request, ar authResult) {
	ctx := r.Context()
	now := h.nowFn()
	providerID := providerIDFromPath(r.URL.Path)
	if providerID == "" {
		writeError(w, r, http.StatusNotFound, codeBadRequest, "unknown endpoint", now, nil)
		return
	}
	if ar.projection != "partner" || ar.matchedKey == nil {
		writeError(w, r, http.StatusUnauthorized, codeUnauthorized, "unauthorized", now, nil)
		return
	}
	if !ar.matchedKey.ProviderID.Valid || ar.matchedKey.ProviderID.String != providerID {
		writeError(w, r, http.StatusForbidden, codeUnauthorized, "unauthorized", now, nil)
		return
	}

	window := r.URL.Query().Get("window")
	if window == "" {
		window = "30d"
	}
	switch window {
	case "24h", "7d", "30d", "all":
	default:
		writeError(w, r, http.StatusBadRequest, codeBadRequest, "invalid window", now, nil)
		return
	}

	row, err := h.Store.LeaderboardProvider(ctx, window, providerID)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "provider stats read failed", now, nil)
		return
	}
	if row == nil {
		gen, gerr := h.Store.ComponentGeneratedAt(ctx, "leaderboard_"+window)
		if gerr != nil {
			writeError(w, r, http.StatusInternalServerError, codeInternal, "components_health read failed", now, nil)
			return
		}
		if gen.IsZero() || h.leaderboardStaleFor503(gen, now, window) {
			retry := 30
			writeError(w, r, http.StatusServiceUnavailable, codeStatsStale, "provider stats are stale", now, &retry)
			return
		}
		idle := h.providerIdlePrewarm(ctx, providerID)
		resp := providerStatsResponse{
			GeneratedAt: gen.UTC().Format(time.RFC3339),
			StaleAfter:  gen.Add(30 * time.Second).UTC().Format(time.RFC3339),
			Window:      window,
			ProviderID:  providerID,
			Row: leaderboardRespRow{
				Rank:           0,
				Pseudonym:      "",
				EarningsBucket: "-",
				Tokens:         0,
				Jobs:           0,
			},
			IdlePrewarm: providerIdlePrewarmSummary(idle),
		}
		writeJSON(w, r, http.StatusOK, resp, gen, "private, max-age=30, s-maxage=30", varyForPartner(), ar)
		return
	}
	if h.leaderboardStaleFor503(row.GeneratedAt, now, window) {
		retry := 30
		writeError(w, r, http.StatusServiceUnavailable, codeStatsStale, "provider stats are stale", now, &retry)
		return
	}
	if obs := requestObsFromContext(r.Context()); obs != nil {
		obs.GeneratedAtAgeMs = time.Since(row.GeneratedAt).Milliseconds()
	}
	idle := h.providerIdlePrewarm(ctx, providerID)

	earn := parseUSD(row.EarningsTotalUSD)
	work := parseUSD(row.EarningsWorkUSD)
	reward := parseUSD(row.EarningsRewardsUSD)
	earnCopy := earn
	workCopy := work
	rewardCopy := reward
	respRow := leaderboardRespRow{
		Rank:               row.RankEarnings,
		Pseudonym:          row.Pseudonym,
		EarningsBucket:     row.Bucket,
		Tokens:             row.Tokens,
		Jobs:               row.Jobs,
		EarningsUSD:        &earnCopy,
		EarningsWorkUSD:    &workCopy,
		EarningsRewardsUSD: &rewardCopy,
	}
	if row.FirstSeenAt.Valid {
		respRow.FirstSeenAt = row.FirstSeenAt.Time.UTC().Format(time.RFC3339)
	}
	if row.LastSeenAt.Valid {
		respRow.LastSeenAt = row.LastSeenAt.Time.UTC().Format(time.RFC3339)
	}
	resp := providerStatsResponse{
		GeneratedAt: row.GeneratedAt.UTC().Format(time.RFC3339),
		StaleAfter:  row.GeneratedAt.Add(30 * time.Second).UTC().Format(time.RFC3339),
		Window:      window,
		ProviderID:  providerID,
		Row:         respRow,
		IdlePrewarm: providerIdlePrewarmSummary(idle),
	}
	writeJSON(w, r, http.StatusOK, resp, row.GeneratedAt, "private, max-age=30, s-maxage=30", varyForPartner(), ar)
}

func (h *Handler) providerIdlePrewarm(ctx context.Context, providerID string) store.ProviderIdlePrewarmSummary {
	read := h.Store.ProviderIdlePrewarm
	if h.idlePrewarmRead != nil {
		read = h.idlePrewarmRead
	}
	idleCtx, cancel := context.WithTimeout(ctx, providerIdlePrewarmReadTimeout)
	defer cancel()
	idle, err := read(idleCtx, providerID)
	if err != nil {
		h.Logger.Warn().Err(err).Str("provider_id", providerID).Msg("provider idle prewarm read failed; returning empty optional block")
		return store.ProviderIdlePrewarmSummary{
			EventsLast1h:        map[string]int64{},
			SkipsByReasonLast1h: map[string]int64{},
		}
	}
	return idle
}

func providerIdlePrewarmSummary(in store.ProviderIdlePrewarmSummary) providerIdlePrewarmResponse {
	return providerIdlePrewarmResponse{
		EventsLast1h:        in.EventsLast1h,
		SkipsByReasonLast1h: in.SkipsByReasonLast1h,
	}
}

func decodeReasonCounts(raw []byte) map[string]int64 {
	out := map[string]int64{}
	if len(raw) == 0 {
		return out
	}
	_ = json.Unmarshal(raw, &out)
	return out
}

// leaderboardStaleFor503 returns true iff the leaderboard
// snapshot is older than the §9.5 503 budget for `window`.
// Empty snapshot (zero time) is treated as stale.
func (h *Handler) leaderboardStaleFor503(snapshotTime, now time.Time, window string) bool {
	if snapshotTime.IsZero() {
		return false // empty table is valid (no providers in window).
	}
	budget := time.Duration(leaderboardStaleBudgetSeconds(window)) * time.Second
	return now.Sub(snapshotTime) > budget
}

func parseUSD(s string) float64 {
	if s == "" {
		return 0
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return v
}

func round2(v float64) float64 {
	// Round to 2 decimals; JSON encoding picks shortest float
	// repr, which for .00-aligned values may emit e.g. "5".
	// SPEC §5.2 calls for "two-decimal precision"; clients
	// parse JSON numbers without trailing-zero requirement.
	return float64(int64(v*100+sign(v)*0.5)) / 100
}

func sign(v float64) float64 {
	if v < 0 {
		return -1
	}
	return 1
}

func (h *Handler) shouldExposePartialHistorySince(window string, now time.Time) bool {
	// Round-2 CODE H5 fix: gate on BackfillMode == "partial"
	// per §9.7 Path A. Path B (full) MUST omit the field even
	// if a stale PartialSince config value is left behind.
	if h.BackfillMode != "partial" {
		return false
	}
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
		// 'all' is open-ended; expose iff < 90 days since since.
		winLen = 90 * 24 * time.Hour
	}
	return now.Sub(t) < winLen
}

// ===========================================================================
// §5.3 /v1/stats/health
// ===========================================================================

// healthResponse mirrors the locked §5.3 wire shape:
//
//	{ status, generated_at, rollup_lag_seconds,
//	  components{7 keys} }
type healthResponse struct {
	Status           string                     `json:"status"`
	GeneratedAt      string                     `json:"generated_at"`
	RollupLagSeconds int                        `json:"rollup_lag_seconds"`
	Components       map[string]healthComponent `json:"components"`
}

type healthComponent struct {
	Status      string `json:"status"`
	GeneratedAt string `json:"generated_at"`
}

// healthComponentKeys is the locked §5.3 7-key set. The
// handler emits every key even if a `stats_components_health`
// row is missing — missing rows default to "down" with epoch
// generated_at.
var healthComponentKeys = []string{
	"overview",
	"timeseries_rpm",
	"timeseries_tpm",
	"leaderboard_24h",
	"leaderboard_7d",
	"leaderboard_30d",
	"leaderboard_all",
}

func (h *Handler) handleHealth(w http.ResponseWriter, r *http.Request, ar authResult) {
	ctx := r.Context()
	now := h.nowFn()

	comps, err := h.Store.ComponentsHealth(ctx)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "health read failed", now, nil)
		return
	}
	byKey := make(map[string]time.Time, len(comps))
	for _, c := range comps {
		byKey[c.Component] = c.GeneratedAt
	}
	compMap := make(map[string]healthComponent, 7)
	var oldest time.Time
	for _, k := range healthComponentKeys {
		gen, ok := byKey[k]
		if !ok {
			gen = time.Time{}
		}
		s := statusFromFreshness(now, gen, k)
		compMap[k] = healthComponent{
			Status:      s,
			GeneratedAt: gen.UTC().Format(time.RFC3339),
		}
		if !gen.IsZero() && (oldest.IsZero() || gen.Before(oldest)) {
			oldest = gen
		}
	}

	// §5.3 top-level derivation:
	//   "down" iff overview OR leaderboard_24h beyond §5.8 budget;
	//   "degraded" iff any component beyond §9.5 target;
	//   "ok" otherwise.
	overall := "ok"
	if compMap["overview"].Status == "down" || compMap["leaderboard_24h"].Status == "down" {
		overall = "down"
	} else {
		for _, c := range compMap {
			if c.Status == "degraded" || c.Status == "down" {
				overall = "degraded"
				break
			}
		}
	}

	lag := 0
	if !oldest.IsZero() {
		lag = int(now.Sub(oldest).Seconds())
		if lag < 0 {
			lag = 0
		}
	}

	resp := healthResponse{
		Status:           overall,
		GeneratedAt:      now.Format(time.RFC3339),
		RollupLagSeconds: lag,
		Components:       compMap,
	}
	// /v1/stats/health returns 200 even when degraded/down
	// per §5.3.
	writeJSON(w, r, http.StatusOK, resp, now,
		"public, max-age=10, s-maxage=10", varyForPublic(), ar)
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
		now := time.Now().UTC()
		writeError(w, r, http.StatusInternalServerError, codeInternal, "marshal failed", now, nil)
		return
	}
	etag := weakETag(buf)
	// Final adversarial audit (claude-subagent HIGH 1) — the
	// 304 Not Modified branch MUST emit the same §5.7 CORS
	// headers as the 200 branch. The Fetch spec requires
	// `Access-Control-Allow-Origin` on EVERY cross-origin
	// response (including 304), so a browser issuing a
	// conditional GET with `If-None-Match` from
	// console.streamvc.live / portal.streamvc.live would
	// otherwise reject the response as a CORS failure even
	// though the response is functionally correct. SPEC §5.7's
	// CORS table carves out no 304 exception. Move the CORS
	// header write BEFORE the 304 branch so both paths emit it.
	writeCORSHeaders(w, ar.projection == "partner", ar.originPresent, ar.originValue)
	if ifNoneMatchEquals(r.Header.Get("If-None-Match"), etag) {
		// 304 carries the RFC 7232 conditional-GET headers per
		// §5.9 (no body, no X-Stats-Generated-At) AND the
		// projection-aware CORS headers emitted above.
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
//
// Round-1 SECURITY L2 fix: only EXACT-match paths are accepted;
// `/v1/stats/overview/extra` returns "" (404) rather than
// routing as `overview`.
func trimEndpointFromPath(p string) string {
	const prefix = "/v1/stats/"
	if !strings.HasPrefix(p, prefix) {
		return ""
	}
	rest := p[len(prefix):]
	switch rest {
	case "overview", "leaderboard", "health":
		return rest
	}
	if providerIDFromPath(p) != "" {
		return "provider"
	}
	return ""
}

func providerIDFromPath(p string) string {
	const prefix = "/v1/stats/provider/"
	if !strings.HasPrefix(p, prefix) {
		return ""
	}
	rest := strings.TrimPrefix(p, prefix)
	if rest == "" || strings.Contains(rest, "/") {
		return ""
	}
	return rest
}
