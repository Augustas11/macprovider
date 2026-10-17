package ws

// SPEC-036 §5A cross-provider scoring engine (FR-20 through FR-25).
//
// The engine injects verification requests through the ordinary buyer
// dispatch path (an injected dispatcher, because ws cannot import buyer),
// asks independent scorers of other operators for teacher-forced
// log-probabilities of the output, decides each measurement against the
// learned honest-pair band, and drives the FR-23 state machine. It never
// logs or persists prompts, outputs or scorer token data.

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const (
	computeScoreRequestType     = "compute_score_request_v1"
	computeScoreResultType      = "compute_score_result_v1"
	maxComputeScoreResultBytes  = 4 * 1024
	computeScoreOperatorTTL     = 10 * time.Minute
	computeScoreDispatchTimeout = 5 * time.Minute

	// FR-21 bounds, enforced on both sides of the wire.
	computeScoreMaxPromptTokens = 4096
	computeScoreMaxScoredTokens = 512
	computeScoreMaxOutputBytes  = 32 * 1024
	computeScoreLogprobFloor    = 100.0

	// computeScoreRetention bounds in-memory history: tolerance windows and
	// known sequences of a (model, manifest) unseen this long are dropped,
	// and so are in-memory states of absent providers in unverified or
	// passing (their durable rows stay). Adverse states are never pruned.
	computeScoreRetention = 7 * 24 * time.Hour
	// computeScoreDurableRetention bounds durable unverified/passing rows.
	computeScoreDurableRetention = 30 * 24 * time.Hour
	// computeScoreNegativeTTL caches a failed operator-key lookup briefly so
	// an identity-store outage is not amplified by every sweep.
	computeScoreNegativeTTL = time.Minute
	// computeScoreCommitTimeout bounds one transition commit, which runs
	// under the engine lock.
	computeScoreCommitTimeout = 5 * time.Second
	// computeScoreShortOutputBytes is the output size above which a scorer
	// reporting fewer than MinScoredTokens tokens is answering short rather
	// than the output being short (64 bytes per token, far above any real
	// tokenizer's average).
	computeScoreShortOutputBytes = computeintegrity.MinScoredTokens * 64
	// computeScoreLookupTimeout bounds one operator-identity lookup or one
	// maintenance write, so a slow store delays a sweep, never stalls it.
	computeScoreLookupTimeout = 2 * time.Second
	// computeScoreOverdueSpread bounds how long after a restart a key whose
	// persisted due time has passed waits: it is redrawn uniformly within
	// this window (or its interval, if shorter), so many overdue keys do not
	// all fire at once.
	computeScoreOverdueSpread = 15 * time.Minute
	// computeScoreScheduleBatch bounds one schedule flush; the rest stays
	// queued for the next sweep.
	computeScoreScheduleBatch = 512
)

// ComputeScoreRequest is the FR-21 coordinator-to-scorer frame.
type ComputeScoreRequest struct {
	Type                  string `json:"type"`
	Version               int    `json:"version"`
	ScoreID               string `json:"score_id"`
	ProviderID            string `json:"provider_id"`
	AssignedID            string `json:"assigned_id"`
	ModelID               string `json:"model_id"`
	WeightsManifestSHA256 string `json:"weights_manifest_sha256"`
	Body                  string `json:"body"`
	OutputText            string `json:"output_text"`
	ReasoningText         string `json:"reasoning_text"`
	IssuedAt              string `json:"issued_at"`
	ExpiresAt             string `json:"expires_at"`
}

// ComputeScoreResult is the FR-21 scorer-to-coordinator frame.
type ComputeScoreResult struct {
	Type                  string  `json:"type"`
	Version               int     `json:"version"`
	ScoreID               string  `json:"score_id"`
	ProviderID            string  `json:"provider_id"`
	AssignedID            string  `json:"assigned_id"`
	ModelID               string  `json:"model_id"`
	WeightsManifestSHA256 string  `json:"weights_manifest_sha256"`
	Status                string  `json:"status"`
	PromptTokens          int     `json:"prompt_tokens"`
	ScoredTokens          int     `json:"scored_tokens"`
	Top1Matches           int     `json:"top1_matches"`
	SumLogprob            float64 `json:"sum_logprob"`
}

var computeScoreResultFields = map[string]struct{}{
	"type": {}, "version": {}, "score_id": {}, "provider_id": {}, "assigned_id": {}, "model_id": {},
	"weights_manifest_sha256": {}, "status": {}, "prompt_tokens": {}, "scored_tokens": {},
	"top1_matches": {}, "sum_logprob": {},
}

// errComputeScoreResultInvalid is the only error ParseComputeScoreResult
// returns: callers log the closed field category, never scorer-controlled
// text.
var errComputeScoreResultInvalid = errors.New("invalid compute score result")

// ParseComputeScoreResult strictly decodes an FR-21 result frame and enforces
// the FR-21 bounds coordinator-side. The returned field is a closed category.
func ParseComputeScoreResult(payload []byte) (ComputeScoreResult, string, error) {
	if len(payload) > maxComputeScoreResultBytes {
		return ComputeScoreResult{}, "payload", errComputeScoreResultInvalid
	}
	if _, err := rejectDuplicateJSONFields(payload); err != nil {
		return ComputeScoreResult{}, "json", errComputeScoreResultInvalid
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return ComputeScoreResult{}, "json", errComputeScoreResultInvalid
	}
	if field := rejectUnknownFields(raw, computeScoreResultFields); field != "" {
		return ComputeScoreResult{}, "unknown_field", errComputeScoreResultInvalid
	}
	var result ComputeScoreResult
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&result); err != nil {
		return ComputeScoreResult{}, "json", errComputeScoreResultInvalid
	}
	switch {
	case result.Type != computeScoreResultType:
		return ComputeScoreResult{}, "type", errComputeScoreResultInvalid
	case result.Version != 1:
		return ComputeScoreResult{}, "version", errComputeScoreResultInvalid
	case !boundedPrintable(result.ScoreID, 1, 128):
		return ComputeScoreResult{}, "score_id", errComputeScoreResultInvalid
	case !boundedPrintable(result.ProviderID, 1, 256), !boundedPrintable(result.AssignedID, 1, 256), !boundedPrintable(result.ModelID, 1, 256):
		return ComputeScoreResult{}, "identity", errComputeScoreResultInvalid
	case !isLowerHex64(result.WeightsManifestSHA256):
		return ComputeScoreResult{}, "weights_manifest_sha256", errComputeScoreResultInvalid
	}
	switch result.Status {
	case "ok":
		if result.PromptTokens < 0 || result.PromptTokens > computeScoreMaxPromptTokens ||
			result.ScoredTokens < 0 || result.ScoredTokens > computeScoreMaxScoredTokens ||
			result.Top1Matches < 0 || result.Top1Matches > result.ScoredTokens ||
			math.IsNaN(result.SumLogprob) || math.IsInf(result.SumLogprob, 0) ||
			result.SumLogprob > 0 || result.SumLogprob < -computeScoreLogprobFloor*float64(result.ScoredTokens) {
			return ComputeScoreResult{}, "counts", errComputeScoreResultInvalid
		}
	case "unavailable", "invalid", "too_long":
		if result.PromptTokens != 0 || result.ScoredTokens != 0 || result.Top1Matches != 0 || result.SumLogprob != 0 {
			return ComputeScoreResult{}, "counts", errComputeScoreResultInvalid
		}
	default:
		return ComputeScoreResult{}, "status", errComputeScoreResultInvalid
	}
	return result, "", nil
}

// ComputeIntegrityProbeDispatch is one FR-20 verification request, pinned to
// one provider session.
type ComputeIntegrityProbeDispatch struct {
	ProviderID string
	AssignedID string
	ModelID    string
	Body       []byte
	MaxTokens  int
}

// ComputeIntegrityProbeResponse is the verified provider's answer, held in
// memory only for scoring.
type ComputeIntegrityProbeResponse struct {
	OutputText    string
	ReasoningText string
	Complete      bool
}

// ComputeIntegrityProbeDispatcher sends a verification request through the
// ordinary buyer dispatch path, pinned to one provider session.
type ComputeIntegrityProbeDispatcher func(context.Context, ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error)

// ComputeIntegrityHoldStore is the SPEC-022 R-16 hold store. Hold actions run
// inside the transaction that persists the FR-23 state, which must be on the
// same database.
type ComputeIntegrityHoldStore interface {
	ApplyComputeIntegrityHoldAction(ctx context.Context, tx *sql.Tx, providerID, modelID string, action computeintegrity.HoldAction, reason string, now time.Time) error
	ComputeIntegrityHolds(ctx context.Context, providerID string) ([]computeintegrity.EarningsHold, error)
	ReleaseComputeIntegrityHold(ctx context.Context, holdID int64, operatorID, reason string, now time.Time) (computeintegrity.EarningsHold, error)
	CountHeldComputeIntegrityHolds(ctx context.Context) (int, error)
}

// ComputeScoringMetrics is the FR-25 closed-label telemetry sink.
type ComputeScoringMetrics interface {
	IncComputeIntegrityVerification(outcome string)
	IncComputeIntegrityInconclusive(reason string)
	IncComputeIntegrityTransition(from, to string)
	IncComputeIntegrityScoringJob(status string)
	SetComputeIntegrityKeys(state string, n int)
	SetComputeIntegrityHeldHolds(n int)
}

// ComputeScoringDeps wires the engine.
type ComputeScoringDeps struct {
	Config      config.ComputeIntegrityScoringConfig
	Store       *computeintegrity.ScoringStore
	Dispatch    ComputeIntegrityProbeDispatcher
	OperatorKey func(ctx context.Context, providerID string) (string, error)
	Holds       ComputeIntegrityHoldStore
	Metrics     ComputeScoringMetrics
	Corpus      computeintegrity.Corpus
	Rand        *rand.Rand
}

type computeScoringKey struct {
	providerID string
	modelID    string
}

type pendingComputeScore struct {
	scorerID   string
	assignedID string
	modelID    string
	// manifest is the wire manifest sent to the scorer, which it echoes.
	manifest string
	deadline time.Time
	ch       chan ComputeScoreResult
}

type cachedOperatorKey struct {
	key     string
	fetched time.Time
}

// scorerPoolKey is a scorer cohort: one model at one coordinator-verified
// catalog model hash.
type scorerPoolKey struct {
	modelID   string
	modelHash string
}

type computeScoringEngine struct {
	s    *Server
	deps ComputeScoringDeps

	// lastSeen records when each provider was last in the pool, for pruning.
	lastSeen map[string]time.Time
	// pendingExclusions are FR-24 exclusions not yet persisted; every sweep
	// retries them. exclusionMu serializes exclusion writes, retries and
	// operator clears, so a retry never restores an exclusion an operator
	// cleared.
	pendingExclusions map[string]time.Time
	exclusionMu       sync.Mutex
	lastDurablePrune  time.Time

	// pendingMu guards pending alone, so a scorer's result frame, handled on
	// its receive loop, never waits for engine work that holds mu.
	pendingMu sync.Mutex
	pending   map[string]*pendingComputeScore

	tolerance *computeintegrity.Tolerance
	scorers   *computeintegrity.ScorerTracker
	known     *computeintegrity.KnownSequences

	mu      sync.Mutex
	rng     *rand.Rand
	states  map[computeScoringKey]*computeintegrity.KeyState
	nextDue map[computeScoringKey]time.Time
	// dirtyDue holds due-time changes not yet persisted; a zero time deletes
	// the key's row. Each sweep flushes it.
	dirtyDue map[computeScoringKey]time.Time
	// scheduleLost is set when the persisted schedule could not be read at
	// start: every key is then treated as overdue at first sight, so an
	// unreadable schedule never delays verification.
	scheduleLost  bool
	inFlight      map[computeScoringKey]bool
	inFlightCount int
	// recentStarts holds the start times of the verification requests of
	// the last rolling hour (FR-20 max_per_hour).
	recentStarts []time.Time
	// pendingStarts counts reserved requests not yet dispatched; they use
	// hourly budget until their start is recorded at dispatch.
	pendingStarts int
	// startWriteMu serializes durable start writes (beginDispatch).
	startWriteMu sync.Mutex
	scoringJobs  int
	operatorKeys map[string]cachedOperatorKey
	// scorerBusy reserves a scorer for one job at a time: the provider runs
	// one scoring job at a time and rejects a second as unavailable.
	scorerBusy map[string]bool
	// dispatchDelay spreads a due request uniformly over one sweep interval,
	// so request arrival carries no sweep-tick phase.
	dispatchDelay func() time.Duration
}

// Inconclusive reasons (FR-23).
const (
	ciInconclusiveDispatch      = "dispatch"
	ciInconclusiveNoScorer      = "no_scorer"
	ciInconclusiveScorerTimeout = "scorer_timeout"
	ciInconclusiveShortOutput   = "short_output"
	ciInconclusiveScorerInvalid = "scorer_invalid"
)

// StartComputeScoring loads persisted state, applies routing suspensions, and
// starts the FR-20 scheduler. It runs until ctx is done. It always loads
// state, even with scoring disabled, so a failed key stays out of routing.
func (s *Server) StartComputeScoring(ctx context.Context, deps ComputeScoringDeps) error {
	e, err := s.newComputeScoringEngine(ctx, deps)
	if err != nil {
		return err
	}
	go e.run(ctx)
	return nil
}

func (s *Server) newComputeScoringEngine(ctx context.Context, deps ComputeScoringDeps) (*computeScoringEngine, error) {
	if deps.Store == nil || deps.Dispatch == nil || deps.OperatorKey == nil || deps.Holds == nil {
		return nil, errors.New("compute scoring: store, dispatcher, operator lookup and hold store are required")
	}
	if deps.Corpus == nil {
		deps.Corpus = computeintegrity.DefaultCorpus()
	}
	rng := deps.Rand
	if rng == nil {
		rng = rand.New(rand.NewSource(time.Now().UnixNano()))
	}
	states, err := deps.Store.LoadKeyStates(ctx)
	if err != nil {
		return nil, err
	}
	excluded, err := deps.Store.LoadScorerExclusions(ctx)
	if err != nil {
		return nil, err
	}
	e := &computeScoringEngine{
		s:            s,
		deps:         deps,
		tolerance:    computeintegrity.NewTolerance(),
		scorers:      computeintegrity.NewScorerTracker(excluded),
		known:        computeintegrity.NewKnownSequences(),
		rng:          rng,
		states:       map[computeScoringKey]*computeintegrity.KeyState{},
		nextDue:      map[computeScoringKey]time.Time{},
		dirtyDue:     map[computeScoringKey]time.Time{},
		inFlight:     map[computeScoringKey]bool{},
		pending:      map[string]*pendingComputeScore{},
		operatorKeys: map[string]cachedOperatorKey{},
		lastSeen:     map[string]time.Time{},
		scorerBusy:   map[string]bool{},

		pendingExclusions: map[string]time.Time{},
	}
	// The rolling hourly bound survives a restart: reload the start times of
	// the verification requests already sent in the last hour.
	// If the history cannot be read, the bound fails closed: the whole
	// budget counts as spent at start and frees after one hour.
	startedAt := s.now()
	starts, err := deps.Store.RecentVerificationRequests(ctx, startedAt.Add(-time.Hour), deps.Config.MaxPerHour)
	if err != nil {
		s.log.Warn().Str("event", "compute_integrity_hourly_history_unavailable").Msg("verification history unreadable; hourly budget treated as spent for one hour")
		starts = nil
		for i := 0; i < deps.Config.MaxPerHour; i++ {
			starts = append(starts, startedAt)
		}
	}
	for i := len(starts) - 1; i >= 0; i-- {
		e.recentStarts = append(e.recentStarts, starts[i])
	}
	sweep := e.tickInterval()
	e.dispatchDelay = func() time.Duration {
		e.mu.Lock()
		defer e.mu.Unlock()
		return time.Duration(e.rng.Int63n(int64(sweep)))
	}
	for _, st := range states {
		st.RecoveryCooldown = e.recoveryCooldown()
		// A restored key counts as seen at start, so it survives until its
		// provider has been away for the retention period, as if the
		// coordinator had not restarted.
		e.lastSeen[st.ProviderID] = startedAt
		e.states[computeScoringKey{st.ProviderID, st.ModelID}] = st
		if st.State.RoutingSuspended() && s.pool != nil {
			s.pool.SetComputeIntegritySuspended(st.ProviderID, st.ModelID, true)
		}
	}
	e.restoreSchedule(ctx, startedAt)
	s.computeScoring.Store(e)
	return e, nil
}

// restoreSchedule reloads the persisted due times (FR-20), so a restart does
// not reset the cadence. A key whose due time has passed is redrawn within a
// short bounded window; a due time beyond the longest jittered interval (a
// shortened interval or a clock step) is redrawn as a fresh interval. These
// redraws stay in memory: the stored row changes only when the engine
// schedules the key for a present provider, so restarts never refresh an
// absent provider's row. A row neither written nor due within the retention
// period is ignored. An unreadable schedule makes every key overdue at first
// sight.
func (e *computeScoringEngine) restoreSchedule(ctx context.Context, startedAt time.Time) {
	schedule, err := e.deps.Store.LoadProbeSchedule(ctx)
	if err != nil {
		e.s.log.Warn().Str("event", "compute_integrity_schedule_unavailable").Msg("verification schedule unreadable; keys are treated as overdue")
		e.scheduleLost = true
		return
	}
	stale := startedAt.Add(-computeScoreRetention)
	for _, d := range schedule {
		if d.UpdatedAt.Before(stale) && d.Due.Before(stale) {
			continue
		}
		key := computeScoringKey{d.ProviderID, d.ModelID}
		state := computeintegrity.VerificationUnverified
		if st := e.states[key]; st != nil {
			state = st.State
		}
		interval := e.interval(state)
		due := d.Due
		switch {
		case !due.After(startedAt):
			due = e.overdueDue(startedAt, interval)
		case due.Sub(startedAt) > interval*3/2:
			due = startedAt.Add(e.jitter(interval))
		}
		e.nextDue[key] = due
		// Like a restored state, a restored due time counts as seen at start.
		if _, ok := e.lastSeen[d.ProviderID]; !ok {
			e.lastSeen[d.ProviderID] = startedAt
		}
	}
}

// overdueDue draws the due time of an overdue key uniformly within the
// overdue window. Caller holds mu (or owns the engine before it starts).
func (e *computeScoringEngine) overdueDue(now time.Time, interval time.Duration) time.Time {
	spread := min(computeScoreOverdueSpread, interval)
	if spread <= 0 {
		return now
	}
	return now.Add(time.Duration(e.rng.Int63n(int64(spread))))
}

// setDueLocked schedules key and marks the change for persistence. Caller
// holds mu.
func (e *computeScoringEngine) setDueLocked(key computeScoringKey, due time.Time) {
	e.nextDue[key] = due
	e.dirtyDue[key] = due
}

// dropDueLocked unschedules key and marks the deletion for persistence.
// Caller holds mu.
func (e *computeScoringEngine) dropDueLocked(key computeScoringKey) {
	delete(e.nextDue, key)
	e.dirtyDue[key] = time.Time{}
}

// flushSchedule persists queued due-time changes, at most one batch. Only the
// sweep goroutine flushes, so writes of one key stay in order. A failed
// batch is retried unless the key changed again meanwhile. A key with an
// unwritten change is not dispatched (considerProvider), so the store never
// lags a probe. A crash loses the changes not yet written: the restart then
// uses the older stored due time. The write outlives ctx cancellation, so a
// shutdown still persists the last changes.
func (e *computeScoringEngine) flushSchedule(ctx context.Context, now time.Time) {
	e.mu.Lock()
	if len(e.dirtyDue) == 0 {
		e.mu.Unlock()
		return
	}
	pending := make(map[computeScoringKey]time.Time, min(len(e.dirtyDue), computeScoreScheduleBatch))
	for key, due := range e.dirtyDue {
		if len(pending) == computeScoreScheduleBatch {
			break
		}
		pending[key] = due
		delete(e.dirtyDue, key)
	}
	e.mu.Unlock()
	batch := make([]computeintegrity.ProbeDue, 0, len(pending))
	for key, due := range pending {
		batch = append(batch, computeintegrity.ProbeDue{ProviderID: key.providerID, ModelID: key.modelID, Due: due})
	}
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), computeScoreCommitTimeout)
	err := e.deps.Store.SaveProbeSchedule(wctx, batch, now)
	cancel()
	if err == nil {
		return
	}
	e.s.log.Warn().Str("event", "compute_integrity_schedule_write_failed").Msg("verification schedule write failed; retrying next sweep")
	e.mu.Lock()
	for key, due := range pending {
		if _, newer := e.dirtyDue[key]; !newer {
			e.dirtyDue[key] = due
		}
	}
	e.mu.Unlock()
}

func (e *computeScoringEngine) recoveryCooldown() time.Duration {
	return time.Duration(e.deps.Config.RecoveryCooldownSeconds) * time.Second
}

func (e *computeScoringEngine) interval(state computeintegrity.VerificationState) time.Duration {
	if state.Escalating() {
		return time.Duration(e.deps.Config.EscalationIntervalSeconds) * time.Second
	}
	return time.Duration(e.deps.Config.BaseIntervalSeconds) * time.Second
}

// jitter returns d scaled by a uniform factor in [0.5, 1.5). Caller holds mu.
func (e *computeScoringEngine) jitter(d time.Duration) time.Duration {
	return time.Duration(float64(d) * (0.5 + e.rng.Float64()))
}

func (e *computeScoringEngine) tickInterval() time.Duration {
	sweep := time.Duration(e.deps.Config.SweepIntervalSeconds) * time.Second
	if sweep <= 0 {
		sweep = 30 * time.Second
	}
	return sweep
}

func (e *computeScoringEngine) run(ctx context.Context) {
	ticker := time.NewTicker(e.tickInterval())
	defer ticker.Stop()
	for {
		e.sweep(ctx, e.s.now())
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (e *computeScoringEngine) operatorKey(ctx context.Context, providerID string, now time.Time) string {
	e.mu.Lock()
	cached, ok := e.operatorKeys[providerID]
	e.mu.Unlock()
	if ok && cached.key != "" && now.Sub(cached.fetched) < computeScoreOperatorTTL {
		return cached.key
	}
	if ok && cached.key == "" && now.Sub(cached.fetched) < computeScoreNegativeTTL {
		return ""
	}
	lctx, cancel := context.WithTimeout(ctx, computeScoreLookupTimeout)
	key, err := e.deps.OperatorKey(lctx, providerID)
	cancel()
	if err != nil && ctx.Err() != nil {
		// Cut off by the caller's deadline, not a lookup failure: nothing is
		// cached, so the next sweep retries at once.
		return ""
	}
	if err != nil || key == "" {
		e.mu.Lock()
		e.operatorKeys[providerID] = cachedOperatorKey{fetched: now}
		e.mu.Unlock()
		return ""
	}
	e.mu.Lock()
	e.operatorKeys[providerID] = cachedOperatorKey{key: key, fetched: now}
	e.mu.Unlock()
	return key
}

func providerScoringReady(p pool.Provider) bool {
	return p.State == pool.StateReady || p.State == pool.StateBusy
}

// providerVerifiable is FR-19: a catalog-verified model with a manifest hash.
func providerVerifiable(p pool.Provider) bool {
	return p.ModelID != "" && isLowerHex64(p.ModelHash) && isLowerHex64(p.WeightsManifestSHA256) &&
		p.HashStatus == pool.HashStatusVerified && providerScoringReady(p)
}

// scoringCandidate is a session as scorer selection sees it: its cohort is
// the coordinator-verified catalog model hash, and its reported manifest is
// only what a scoring job to it carries.
func scoringCandidate(p pool.Provider) computeintegrity.ScorerCandidate {
	return computeintegrity.ScorerCandidate{
		ProviderID:         p.ProviderID,
		AssignedID:         p.AssignedID,
		ModelID:            p.ModelID,
		ManifestSHA256:     p.ModelHash,
		WireManifestSHA256: p.WeightsManifestSHA256,
		Capable:            p.ComputeScoreV1,
		Ready:              true,
	}
}

// stateLocked returns the key state, creating an unverified one. Caller
// holds mu.
func (e *computeScoringEngine) stateLocked(key computeScoringKey, now time.Time) *computeintegrity.KeyState {
	st := e.states[key]
	if st == nil {
		st = computeintegrity.NewKeyState(key.providerID, key.modelID, now)
		st.RecoveryCooldown = e.recoveryCooldown()
		e.states[key] = st
	}
	return st
}

func cloneKeyState(st *computeintegrity.KeyState) computeintegrity.KeyState {
	c := *st
	c.Escalations = append([]computeintegrity.EscalationEntry(nil), st.Escalations...)
	c.StreakScorerOps = append([]string(nil), st.StreakScorerOps...)
	return c
}

func (e *computeScoringEngine) sweep(ctx context.Context, now time.Time) {
	if e.s.pool == nil {
		return
	}
	// Flush before considering keys, so changes since the last sweep are
	// durable before any of them is dispatched, and after, for this sweep's.
	e.flushSchedule(ctx, now)
	defer e.flushSchedule(ctx, now)
	providers := e.s.pool.Snapshot()
	present := make(map[string]struct{}, len(providers))
	for _, p := range providers {
		present[p.ProviderID] = struct{}{}
	}
	// One deadline bounds the whole sweep, maintenance and identity lookups
	// included; work it leaves stays due for the next sweep.
	deadline := time.Now().Add(e.tickInterval())
	e.prune(present, now)
	e.retryExclusions(ctx, now, deadline)
	e.pruneDurable(ctx, now)
	if !e.deps.Config.Enabled {
		e.publishGauges(ctx)
		return
	}
	// One scorer index per sweep, keyed by (model, manifest), so selection
	// costs the size of one model's pool rather than the whole fleet.
	// Operator keys are resolved only for pools with a provider due.
	index := map[scorerPoolKey][]computeintegrity.ScorerCandidate{}
	for _, p := range providers {
		if !providerVerifiable(p) {
			continue
		}
		k := scorerPoolKey{p.ModelID, p.ModelHash}
		e.tolerance.Touch(p.ModelID, p.ModelHash, now)
		index[k] = append(index[k], scoringCandidate(p))
	}
	// Providers are considered in random order within a time budget of one
	// sweep interval; whatever the budget leaves is considered next sweep,
	// and the shuffle keeps any provider from always being last.
	order := make([]int, len(providers))
	for i := range order {
		order[i] = i
	}
	e.mu.Lock()
	e.rng.Shuffle(len(order), func(i, j int) { order[i], order[j] = order[j], order[i] })
	e.mu.Unlock()
	for _, i := range order {
		p := providers[i]
		if !providerVerifiable(p) {
			continue
		}
		if time.Now().After(deadline) {
			break
		}
		e.considerProvider(ctx, p, index[scorerPoolKey{p.ModelID, p.ModelHash}], now, deadline)
	}
	e.publishGauges(ctx)
}

// prune drops schedule and cache entries of providers that left the pool,
// and in-memory history past computeScoreRetention. Adverse key states stay:
// a failed key must survive a disconnect.
func (e *computeScoringEngine) prune(present map[string]struct{}, now time.Time) {
	cutoff := now.Add(-computeScoreRetention)
	e.tolerance.Prune(cutoff)
	e.known.Prune(cutoff)
	e.mu.Lock()
	defer e.mu.Unlock()
	for id := range present {
		e.lastSeen[id] = now
	}
	// A key keeps its due time across a disconnect, so a provider that
	// reconnects resumes an overdue verification instead of drawing a fresh
	// initial interval. Only keys absent past the retention period go.
	for key := range e.nextDue {
		if _, ok := present[key.providerID]; ok || e.inFlight[key] {
			continue
		}
		if seen, ok := e.lastSeen[key.providerID]; !ok || seen.Before(cutoff) {
			e.dropDueLocked(key)
		}
	}
	for id := range e.operatorKeys {
		if _, ok := present[id]; !ok {
			delete(e.operatorKeys, id)
		}
	}
	for key, st := range e.states {
		if _, ok := present[key.providerID]; ok || e.inFlight[key] || !st.State.AcceptsHonestSamples() {
			continue
		}
		if seen, ok := e.lastSeen[key.providerID]; !ok || seen.Before(cutoff) {
			delete(e.states, key)
		}
	}
	for id, seen := range e.lastSeen {
		if seen.Before(cutoff) {
			delete(e.lastSeen, id)
		}
	}
	e.scorers.Prune(func(id string) bool {
		_, ok := e.lastSeen[id]
		return ok
	})
}

// hourlyBudgetLocked drops starts older than one hour and reports whether
// another verification request fits the rolling max_per_hour bound. Caller
// holds mu.
func (e *computeScoringEngine) hourlyBudgetLocked(now time.Time) bool {
	cutoff := now.Add(-time.Hour)
	keep := 0
	for keep < len(e.recentStarts) && !e.recentStarts[keep].After(cutoff) {
		keep++
	}
	e.recentStarts = e.recentStarts[keep:]
	return len(e.recentStarts)+e.pendingStarts < e.deps.Config.MaxPerHour
}

func (e *computeScoringEngine) considerProvider(ctx context.Context, p pool.Provider, candidates []computeintegrity.ScorerCandidate, now, deadline time.Time) {
	key := computeScoringKey{p.ProviderID, p.ModelID}
	e.mu.Lock()
	st := e.stateLocked(key, now)
	before := cloneKeyState(st)
	if tr := st.Tick(now); tr != nil {
		if !e.applyTransitionLocked(ctx, st, tr, now) {
			*st = before
			e.mu.Unlock()
			return
		}
	}
	if st.State == computeintegrity.VerificationFailed || e.inFlight[key] {
		e.mu.Unlock()
		return
	}
	due, scheduled := e.nextDue[key]
	if !scheduled {
		// The first request of a key follows the same jittered cadence, so a
		// new key is never probed at once. A known key's due time is restored
		// at start (restoreSchedule) and never reaches here; if the schedule
		// was unreadable, every key counts as overdue.
		if e.scheduleLost {
			e.setDueLocked(key, e.overdueDue(now, e.interval(st.State)))
		} else {
			e.setDueLocked(key, now.Add(e.jitter(e.interval(st.State))))
		}
		e.mu.Unlock()
		return
	}
	if interval := e.interval(st.State); due.Sub(now) > interval*3/2 {
		// Longer than any draw of the key's current cadence (it entered
		// escalation, or the interval was shortened): redraw.
		e.setDueLocked(key, now.Add(e.jitter(interval)))
		e.mu.Unlock()
		return
	}
	if _, unsaved := e.dirtyDue[key]; unsaved || now.Before(due) || !p.RoutingEligible() {
		e.mu.Unlock()
		return
	}
	if e.inFlightCount >= e.deps.Config.MaxInFlight || !e.hourlyBudgetLocked(now) {
		e.mu.Unlock()
		return
	}
	state := st.State
	e.mu.Unlock()

	verified := scoringCandidate(p)
	// Lookups run under the sweep deadline; past it the key reserves
	// nothing and stays due.
	lctx, cancelLookups := context.WithDeadline(ctx, deadline)
	defer cancelLookups()
	if time.Now().After(deadline) {
		return
	}
	verified.OperatorKey = e.operatorKey(lctx, p.ProviderID, now)
	if time.Now().After(deadline) {
		return
	}
	if verified.OperatorKey == "" {
		// Back off until the next cadence slot instead of retrying the
		// identity lookup every sweep.
		e.mu.Lock()
		e.setDueLocked(key, now.Add(e.jitter(e.interval(state))))
		e.mu.Unlock()
		return
	}
	n := 1
	if state.Escalating() {
		n = 2
	}
	scorerPool := make([]computeintegrity.ScorerCandidate, 0, len(candidates))
	for _, c := range candidates {
		if c.ProviderID == verified.ProviderID || !c.Capable {
			continue
		}
		if time.Now().After(deadline) {
			// Out of sweep time: the key stays due and resumes next sweep
			// with the identities resolved so far cached.
			return
		}
		c.OperatorKey = e.operatorKey(lctx, c.ProviderID, now)
		scorerPool = append(scorerPool, c)
	}
	if time.Now().After(deadline) {
		return
	}
	e.mu.Lock()
	// Acquiring the lock may have waited: the deadline and the hourly bound
	// are checked again as of now, under the lock that reserves.
	if time.Now().After(deadline) || !e.hourlyBudgetLocked(e.s.now()) {
		e.mu.Unlock()
		return
	}
	scorers := computeintegrity.SelectScorers(e.rng, verified, scorerPool, n, func(c computeintegrity.ScorerCandidate) bool {
		return e.scorerEligibleLocked(c, now)
	})
	if len(scorers) < n {
		// A scorer busy with another job would complete the set: stay due
		// and retry next sweep rather than measure with fewer scorers.
		idle := selectableIgnoringBusyLocked(e, verified, scorerPool, n, now)
		if idle > len(scorers) {
			e.mu.Unlock()
			return
		}
	}
	if len(scorers) == 0 {
		e.setDueLocked(key, now.Add(e.jitter(e.interval(state))))
		e.mu.Unlock()
		e.inconclusive(ciInconclusiveNoScorer)
		return
	}
	// Selection ran under the lock; the deadline is checked one last time
	// right at the reservation.
	if time.Now().After(deadline) {
		e.mu.Unlock()
		return
	}
	for _, sc := range scorers {
		e.scorerBusy[sc.ProviderID] = true
	}
	e.inFlight[key] = true
	e.inFlightCount++
	// The reservation uses hourly budget now; its start time is recorded
	// when it is dispatched (runProbe).
	e.pendingStarts++
	e.mu.Unlock()
	go e.runProbe(ctx, verified, scorers)
}

// scorerEligibleLocked applies FR-21 rule 4 and the FR-24 availability
// back-off. Caller holds mu.
func (e *computeScoringEngine) scorerEligibleLocked(c computeintegrity.ScorerCandidate, now time.Time) bool {
	return !e.scorerBusy[c.ProviderID] && e.scorerEligibleIgnoringBusyLocked(c, now)
}

// selectableIgnoringBusyLocked counts the scorers selection would find if no
// scorer were busy. Caller holds mu.
func selectableIgnoringBusyLocked(e *computeScoringEngine, verified computeintegrity.ScorerCandidate, pool []computeintegrity.ScorerCandidate, n int, now time.Time) int {
	return len(computeintegrity.SelectScorers(e.rng, verified, pool, n, func(c computeintegrity.ScorerCandidate) bool {
		return e.scorerEligibleIgnoringBusyLocked(c, now)
	}))
}

// scorerEligibleIgnoringBusyLocked is scorer eligibility apart from the
// one-job reservation. Caller holds mu.
func (e *computeScoringEngine) scorerEligibleIgnoringBusyLocked(c computeintegrity.ScorerCandidate, now time.Time) bool {
	if !e.scorers.Available(c.ProviderID, now) {
		return false
	}
	if st := e.states[computeScoringKey{c.ProviderID, c.ModelID}]; st != nil {
		switch st.State {
		case computeintegrity.VerificationSuspect, computeintegrity.VerificationFailed, computeintegrity.VerificationRecovering:
			return false
		}
	}
	return true
}

func (e *computeScoringEngine) inconclusive(reason string) {
	if e.deps.Metrics != nil {
		e.deps.Metrics.IncComputeIntegrityVerification("inconclusive")
		e.deps.Metrics.IncComputeIntegrityInconclusive(reason)
	}
}

func (e *computeScoringEngine) finishProbe(key computeScoringKey) {
	now := e.s.now()
	e.mu.Lock()
	defer e.mu.Unlock()
	delete(e.inFlight, key)
	e.inFlightCount--
	state := computeintegrity.VerificationUnverified
	if st := e.states[key]; st != nil {
		state = st.State
	}
	e.setDueLocked(key, now.Add(e.jitter(e.interval(state))))
}

type scoredMeasurement struct {
	scorer      computeintegrity.ScorerCandidate
	measurement computeintegrity.Measurement
}

// sessionUnchanged reports whether the verified session still serves the
// same model and manifest it was selected with (FR-20 output binding).
func (e *computeScoringEngine) sessionUnchanged(verified computeintegrity.ScorerCandidate) bool {
	p, ok := e.s.pool.Resolve(verified.ProviderID, verified.AssignedID)
	return ok && p.ModelID == verified.ModelID && p.ModelHash == verified.ManifestSHA256 &&
		p.WeightsManifestSHA256 == verified.WireManifestSHA256 && p.HashStatus == pool.HashStatusVerified
}

func (e *computeScoringEngine) releaseScorers(scorers []computeintegrity.ScorerCandidate) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, sc := range scorers {
		delete(e.scorerBusy, sc.ProviderID)
	}
}

func (e *computeScoringEngine) runProbe(ctx context.Context, verified computeintegrity.ScorerCandidate, scorers []computeintegrity.ScorerCandidate) {
	key := computeScoringKey{verified.ProviderID, verified.ModelID}
	defer e.finishProbe(key)
	defer e.releaseScorers(scorers)
	dispatched := false
	defer func() {
		if !dispatched {
			e.mu.Lock()
			e.pendingStarts--
			e.mu.Unlock()
		}
	}()
	if d := e.dispatchDelay(); d > 0 {
		timer := time.NewTimer(d)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return
		}
	}
	sampledKey := computeintegrity.ToleranceKey{ModelID: verified.ModelID, ManifestSHA256: verified.ManifestSHA256, Class: computeintegrity.SamplingSampled}
	e.mu.Lock()
	greedyOnly := false
	if st := e.states[key]; st != nil && st.State.Escalating() {
		greedyOnly = !e.tolerance.Band(sampledKey).Warm
	}
	escalating := false
	if st := e.states[key]; st != nil {
		escalating = st.State.Escalating()
	}
	probe, err := computeintegrity.DrawProbe(e.rng, e.deps.Corpus, verified.ModelID, greedyOnly, escalating)
	e.mu.Unlock()
	if err != nil {
		e.inconclusive(ciInconclusiveDispatch)
		return
	}
	dispatched = true
	at, ok := e.beginDispatch(ctx)
	if !ok {
		e.inconclusive(ciInconclusiveDispatch)
		return
	}
	if e.s.now().After(at.Add(-computeScoreDispatchTimeout)) {
		// Something held this request so long that a full dispatch timeout
		// no longer fits before its recorded start; it could reach the
		// provider after the time the hourly bound counts, so it is dropped.
		// The recorded start still counts (the safe side).
		e.inconclusive(ciInconclusiveDispatch)
		return
	}
	dctx, cancel := context.WithTimeout(ctx, computeScoreDispatchTimeout)
	defer cancel()
	resp, err := e.deps.Dispatch(dctx, ComputeIntegrityProbeDispatch{
		ProviderID: verified.ProviderID,
		AssignedID: verified.AssignedID,
		ModelID:    verified.ModelID,
		Body:       probe.Body,
		MaxTokens:  probe.MaxTokens,
	})
	if err != nil || !resp.Complete || strings.TrimSpace(resp.OutputText+resp.ReasoningText) == "" ||
		len(resp.OutputText)+len(resp.ReasoningText) > computeScoreMaxOutputBytes ||
		!e.sessionUnchanged(verified) {
		e.inconclusive(ciInconclusiveDispatch)
		return
	}
	if probe.Class == computeintegrity.SamplingHot {
		// Hot requests are cover only (FR-22): honest temperature 1.0 runs
		// can degenerate below any floor (measured to -9.6 on real chips), so
		// a hot output decides nothing and is not sent to scorers.
		return
	}
	measurements, reason, complete := e.scoreAll(ctx, scorers, verified, probe.Body, resp.OutputText, resp.ReasoningText)
	if !complete {
		// FR-23: a measurement counts only when every selected scorer gave a
		// valid answer; anything less changes no state.
		e.inconclusive(reason)
		return
	}
	tkey := computeintegrity.ToleranceKey{ModelID: verified.ModelID, ManifestSHA256: verified.ManifestSHA256, Class: probe.Class}
	e.decide(ctx, key, verified, tkey, measurements, computeintegrity.KnownSequence{
		Body:          probe.Body,
		OutputText:    resp.OutputText,
		ReasoningText: resp.ReasoningText,
	})
}

// scoreAll sends one scoring job per scorer and waits for every answer up to
// the FR-21 deadline. complete is true only when every scorer answered with a
// valid measurement; otherwise reason names the first failure class.
func (e *computeScoringEngine) scoreAll(ctx context.Context, scorers []computeintegrity.ScorerCandidate, verified computeintegrity.ScorerCandidate, body []byte, output, reasoning string) ([]scoredMeasurement, string, bool) {
	type answer struct {
		scorer computeintegrity.ScorerCandidate
		result ComputeScoreResult
		ok     bool
	}
	answers := make(chan answer, len(scorers))
	for _, sc := range scorers {
		go func(sc computeintegrity.ScorerCandidate) {
			result, ok := e.score(ctx, sc, body, output, reasoning, true)
			answers <- answer{scorer: sc, result: result, ok: ok}
		}(sc)
	}
	var out []scoredMeasurement
	var short []string
	reason := ""
	for range scorers {
		a := <-answers
		switch {
		case !a.ok:
			e.scorers.RecordNoAnswer(a.scorer.ProviderID, e.s.now())
			if reason == "" {
				reason = ciInconclusiveScorerTimeout
			}
		case a.result.Status != "ok":
			e.scorers.RecordNoAnswer(a.scorer.ProviderID, e.s.now())
			if reason == "" {
				reason = ciInconclusiveScorerInvalid
			}
		default:
			m := computeintegrity.Measurement{ScoredTokens: a.result.ScoredTokens, Top1Matches: a.result.Top1Matches, SumLogprob: a.result.SumLogprob}
			if !m.Valid() {
				short = append(short, a.scorer.ProviderID)
				if reason == "" {
					reason = ciInconclusiveShortOutput
				}
				continue
			}
			// Only a usable measurement resets the FR-24 silence count.
			e.scorers.RecordAnswer(a.scorer.ProviderID)
			out = append(out, scoredMeasurement{scorer: a.scorer, measurement: m})
		}
	}
	// A short measurement is the scorer's fault when another scorer scored
	// the same output usably, or when the output is long enough that any
	// honest tokenization reaches the FR-21 floor; then it counts as no
	// answer. Otherwise the output itself was short and the count is left
	// alone.
	if len(short) > 0 && (len(out) > 0 || len(output)+len(reasoning) >= computeScoreShortOutputBytes) {
		for _, id := range short {
			e.scorers.RecordNoAnswer(id, e.s.now())
		}
	}
	return out, reason, len(out) == len(scorers) && len(out) > 0
}

// score runs one FR-21 job on one scorer. countJob marks an ordinary scoring
// job, which advances the FR-24 known-sequence cadence.
func (e *computeScoringEngine) score(ctx context.Context, scorer computeintegrity.ScorerCandidate, body []byte, output, reasoning string, countJob bool) (ComputeScoreResult, bool) {
	manifest := scorer.WireManifestSHA256
	session, ok := e.s.storedSessionFor(scorer.ProviderID, scorer.AssignedID)
	if !ok {
		e.scoringJobMetric("timeout")
		return ComputeScoreResult{}, false
	}
	now := e.s.now().UTC()
	deadline := time.Duration(e.deps.Config.ScoreDeadlineSeconds) * time.Second
	scoreID := uuid.NewString()
	req := ComputeScoreRequest{
		Type:                  computeScoreRequestType,
		Version:               1,
		ScoreID:               scoreID,
		ProviderID:            scorer.ProviderID,
		AssignedID:            scorer.AssignedID,
		ModelID:               scorer.ModelID,
		WeightsManifestSHA256: manifest,
		Body:                  string(body),
		OutputText:            output,
		ReasoningText:         reasoning,
		IssuedAt:              now.Format(time.RFC3339Nano),
		ExpiresAt:             now.Add(deadline).Format(time.RFC3339Nano),
	}
	raw, err := json.Marshal(req)
	if err != nil {
		return ComputeScoreResult{}, false
	}
	pending := &pendingComputeScore{
		scorerID: scorer.ProviderID, assignedID: scorer.AssignedID, modelID: scorer.ModelID,
		manifest: manifest, deadline: now.Add(deadline), ch: make(chan ComputeScoreResult, 1),
	}
	e.pendingMu.Lock()
	e.pending[scoreID] = pending
	e.pendingMu.Unlock()
	defer func() {
		e.pendingMu.Lock()
		delete(e.pending, scoreID)
		e.pendingMu.Unlock()
	}()
	if err := session.send(raw); err != nil {
		e.scoringJobMetric("timeout")
		return ComputeScoreResult{}, false
	}
	if countJob {
		// FR-24 cadence counts scoring jobs actually sent.
		e.mu.Lock()
		e.scoringJobs++
		checkKnown := e.scoringJobs%computeintegrity.KnownSequenceCheckEvery == 0
		e.mu.Unlock()
		if checkKnown {
			go e.knownSequenceCheck(ctx, computeintegrity.ToleranceKey{ModelID: scorer.ModelID, ManifestSHA256: scorer.ManifestSHA256})
		}
	}
	timer := time.NewTimer(deadline)
	defer timer.Stop()
	select {
	case result := <-pending.ch:
		e.scoringJobMetric(result.Status)
		return result, true
	case <-timer.C:
	case <-ctx.Done():
	}
	e.scoringJobMetric("timeout")
	return ComputeScoreResult{}, false
}

func (e *computeScoringEngine) scoringJobMetric(status string) {
	if e.deps.Metrics != nil {
		e.deps.Metrics.IncComputeIntegrityScoringJob(status)
	}
}

// decide evaluates the measurements against the band, updates scorer
// agreement, the honest-pair window and the FR-23 state.
func (e *computeScoringEngine) decide(ctx context.Context, key computeScoringKey, verified computeintegrity.ScorerCandidate, tkey computeintegrity.ToleranceKey, ms []scoredMeasurement, seq computeintegrity.KnownSequence) {
	now := e.s.now()
	band := e.tolerance.Band(tkey)
	allIn, allOut := true, true
	var outReason computeintegrity.OutReason
	inBand := make([]bool, len(ms))
	ops := make([]string, 0, len(ms))
	for i, m := range ms {
		ok, reason := band.Evaluate(m.measurement)
		inBand[i] = ok
		if ok {
			allOut = false
		} else {
			allIn = false
			if outReason == "" {
				outReason = reason
			}
		}
		ops = append(ops, m.scorer.OperatorKey)
	}
	if len(ms) == 2 {
		for _, id := range e.scorers.RecordPair(ms[0].scorer.ProviderID, ms[1].scorer.ProviderID, inBand[0] == inBand[1]) {
			e.persistExclusion(ctx, id, now)
		}
		if allIn && tkey.Class != computeintegrity.SamplingHot {
			seq.SourceProvider = verified.ProviderID
			seq.SourceOperator = verified.OperatorKey
			seq.Scorers = []string{ms[0].scorer.ProviderID, ms[1].scorer.ProviderID}
			seq.ScorerOperators = []string{ms[0].scorer.OperatorKey, ms[1].scorer.OperatorKey}
			e.known.Offer(tkey, seq, ms[0].measurement, ms[1].measurement, now)
		}
	}
	outcome := computeintegrity.Outcome{InBand: allIn, OutOfBand: allOut, OutReason: outReason, ScorerOperators: ops, At: now}

	e.mu.Lock()
	st := e.stateLocked(key, now)
	acceptsHonest := st.State.AcceptsHonestSamples()
	before := cloneKeyState(st)
	committed := true
	if tr := st.Apply(outcome); tr != nil {
		committed = e.applyTransitionLocked(ctx, st, tr, now)
	} else if err := e.persistKeyStateLocked(ctx, st, now); err != nil {
		committed = false
		e.s.log.Warn().Str("event", "compute_integrity_state_persist_failed").Str("provider_id", st.ProviderID).Msg("compute-integrity state not persisted; measurement dropped")
	}
	if !committed {
		// Memory never runs ahead of the durable state: the measurement is
		// dropped and the next one retries.
		*st = before
	} else if allIn && acceptsHonest {
		e.tolerance.Accept(tkey, verified.OperatorKey, ms[0].measurement)
	}
	e.mu.Unlock()

	if e.deps.Metrics != nil {
		switch {
		case allIn:
			e.deps.Metrics.IncComputeIntegrityVerification("in_band")
		case allOut:
			e.deps.Metrics.IncComputeIntegrityVerification("out_of_band")
		default:
			e.deps.Metrics.IncComputeIntegrityVerification("split")
		}
	}
}

// persistKeyStateLocked writes a state without a transition under the same
// bound as a transition commit, so a slow database cannot hold mu
// indefinitely. Caller holds mu.
func (e *computeScoringEngine) persistKeyStateLocked(ctx context.Context, st *computeintegrity.KeyState, now time.Time) error {
	ctx, cancel := context.WithTimeout(ctx, computeScoreCommitTimeout)
	defer cancel()
	return e.deps.Store.UpsertKeyState(ctx, st, now)
}

// applyTransitionLocked commits the hold change and the new state in one
// transaction, then publishes the routing suspension. On any failure the
// transaction rolls back, nothing is published, and it returns false so the
// caller restores the previous in-memory state; the next measurement or tick
// retries. Caller holds mu.
func (e *computeScoringEngine) applyTransitionLocked(ctx context.Context, st *computeintegrity.KeyState, tr *computeintegrity.Transition, now time.Time) bool {
	fail := func(err error) bool {
		e.s.log.Error().
			Str("event", "compute_integrity_transition_deferred").
			Str("provider_id", st.ProviderID).
			Str("model_id", st.ModelID).
			Str("to", string(tr.To)).
			Str("error_class", fmt.Sprintf("%T", err)).
			Msg("compute-integrity transition deferred: commit failed")
		return false
	}
	ctx, cancel := context.WithTimeout(ctx, computeScoreCommitTimeout)
	defer cancel()
	tx, err := e.deps.Store.BeginTx(ctx)
	if err != nil {
		return fail(err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := e.deps.Holds.ApplyComputeIntegrityHoldAction(ctx, tx, st.ProviderID, st.ModelID, tr.Hold, string(tr.Reason), now); err != nil {
		return fail(err)
	}
	if err := e.deps.Store.UpsertKeyStateTx(ctx, tx, st, now); err != nil {
		return fail(err)
	}
	if err := tx.Commit(); err != nil {
		return fail(err)
	}
	if e.s.pool != nil {
		e.s.pool.SetComputeIntegritySuspended(st.ProviderID, st.ModelID, tr.To.RoutingSuspended())
	}
	if e.deps.Metrics != nil {
		e.deps.Metrics.IncComputeIntegrityTransition(string(tr.From), string(tr.To))
	}
	e.s.log.Info().
		Str("event", "compute_integrity_transition").
		Str("provider_id", st.ProviderID).
		Str("model_id", st.ModelID).
		Str("from", string(tr.From)).
		Str("to", string(tr.To)).
		Str("reason", string(tr.Reason)).
		Msg("compute-integrity verification state changed")
	return true
}

// persistExclusion writes an FR-24 exclusion. The in-memory exclusion holds
// meanwhile (the conservative side); a failed write is retried every sweep
// until it is durable.
func (e *computeScoringEngine) persistExclusion(ctx context.Context, providerID string, now time.Time) {
	e.exclusionMu.Lock()
	defer e.exclusionMu.Unlock()
	if !e.scorers.Excluded(providerID) {
		// An operator cleared the scorer after the exclusion was decided.
		return
	}
	wctx, cancel := context.WithTimeout(ctx, computeScoreLookupTimeout)
	defer cancel()
	if err := e.deps.Store.ExcludeScorer(wctx, providerID, now); err != nil {
		e.mu.Lock()
		e.pendingExclusions[providerID] = now
		e.mu.Unlock()
		e.s.log.Warn().Str("event", "compute_integrity_scorer_exclusion_persist_failed").Str("provider_id", providerID).Msg("scorer exclusion not persisted; will retry")
		return
	}
	e.s.log.Warn().Str("event", "compute_integrity_scorer_excluded").Str("provider_id", providerID).Msg("compute-integrity scorer excluded")
}

// beginDispatch turns a reservation into a counted start immediately before
// dispatch. The start is made durable first, so a restart always sees it.
// It is stamped at the latest moment the request can reach the provider:
// the write bound plus the dispatch timeout, after which the dispatch
// context cancels it. The caller sends nothing if a full dispatch timeout no
// longer fits before that stamp. If the write fails, the
// request is not sent. Either way the reservation's pending count is
// released.
func (e *computeScoringEngine) beginDispatch(ctx context.Context) (time.Time, bool) {
	// The request reaches the provider, or is cancelled, within the write
	// bound plus the dispatch timeout, so that is the time it counts from.
	at := e.s.now().Add(computeScoreLookupTimeout + computeScoreDispatchTimeout)
	wctx, cancel := context.WithTimeout(ctx, computeScoreLookupTimeout)
	// Start writes are serialized and retried within the bound, so
	// concurrent dispatches do not fail each other on a busy database.
	e.startWriteMu.Lock()
	var err error
	for {
		if err = e.deps.Store.RecordVerificationStart(wctx, at); err == nil || wctx.Err() != nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	e.startWriteMu.Unlock()
	cancel()
	e.mu.Lock()
	defer e.mu.Unlock()
	e.pendingStarts--
	if err != nil {
		e.s.log.Warn().Str("event", "compute_integrity_start_persist_failed").Msg("verification start not persisted; request not sent")
		return at, false
	}
	i := len(e.recentStarts)
	for i > 0 && e.recentStarts[i-1].After(at) {
		i--
	}
	e.recentStarts = append(e.recentStarts, time.Time{})
	copy(e.recentStarts[i+1:], e.recentStarts[i:])
	e.recentStarts[i] = at
	return at, true
}

func (e *computeScoringEngine) retryExclusions(ctx context.Context, now time.Time, deadline time.Time) {
	e.exclusionMu.Lock()
	defer e.exclusionMu.Unlock()
	e.mu.Lock()
	pending := make([]string, 0, len(e.pendingExclusions))
	for id := range e.pendingExclusions {
		pending = append(pending, id)
	}
	e.mu.Unlock()
	for _, id := range pending {
		if time.Now().After(deadline) {
			return
		}
		if e.scorers.Excluded(id) {
			wctx, cancel := context.WithTimeout(ctx, computeScoreLookupTimeout)
			err := e.deps.Store.ExcludeScorer(wctx, id, now)
			cancel()
			if err != nil {
				continue
			}
		}
		e.mu.Lock()
		delete(e.pendingExclusions, id)
		e.mu.Unlock()
	}
}

// pruneDurable bounds the durable key table hourly: unverified and passing
// rows idle for computeScoreDurableRetention go; adverse rows stay.
func (e *computeScoringEngine) pruneDurable(ctx context.Context, now time.Time) {
	if now.Sub(e.lastDurablePrune) < time.Hour {
		return
	}
	e.lastDurablePrune = now
	pctx, cancel := context.WithTimeout(ctx, computeScoreCommitTimeout)
	defer cancel()
	if err := e.deps.Store.PruneVerificationStarts(pctx, now.Add(-2*time.Hour)); err != nil {
		e.s.log.Warn().Str("event", "compute_integrity_start_prune_failed").Msg("verification start prune failed")
	}
	if _, err := e.deps.Store.PruneStaleKeyStates(pctx, now.Add(-computeScoreDurableRetention)); err != nil {
		e.s.log.Warn().Str("event", "compute_integrity_state_prune_failed").Msg("compute-integrity state prune failed")
	}
	if err := e.deps.Store.PruneProbeSchedule(pctx, now.Add(-computeScoreRetention)); err != nil {
		e.s.log.Warn().Str("event", "compute_integrity_schedule_prune_failed").Msg("verification schedule prune failed")
	}
}

// knownSequenceCheck sends one FR-24 known sequence of the model to a random
// eligible scorer that did not score it originally. tkey names the model and
// manifest; every sampling class is eligible.
func (e *computeScoringEngine) knownSequenceCheck(ctx context.Context, tkey computeintegrity.ToleranceKey) {
	now := e.s.now()
	var candidates []computeintegrity.ScorerCandidate
	for _, p := range e.s.pool.Snapshot() {
		if !p.ComputeScoreV1 || !providerVerifiable(p) || p.ModelID != tkey.ModelID || p.ModelHash != tkey.ManifestSHA256 {
			continue
		}
		op := e.operatorKey(ctx, p.ProviderID, now)
		if op == "" {
			continue
		}
		c := scoringCandidate(p)
		c.OperatorKey = op
		candidates = append(candidates, c)
	}
	e.mu.Lock()
	e.rng.Shuffle(len(candidates), func(i, j int) { candidates[i], candidates[j] = candidates[j], candidates[i] })
	var scorer computeintegrity.ScorerCandidate
	var seq computeintegrity.KnownSequence
	found := false
	for _, c := range candidates {
		if !e.scorerEligibleLocked(c, now) {
			continue
		}
		for _, class := range []computeintegrity.SamplingClass{computeintegrity.SamplingGreedy, computeintegrity.SamplingSampled} {
			k := tkey
			k.Class = class
			if s, ok := e.known.Pick(e.rng, k, c); ok {
				scorer, seq, found = c, s, true
				break
			}
		}
		if found {
			break
		}
	}
	if found {
		e.scorerBusy[scorer.ProviderID] = true
	}
	e.mu.Unlock()
	if !found {
		return
	}
	defer e.releaseScorers([]computeintegrity.ScorerCandidate{scorer})
	result, answered := e.score(ctx, scorer, seq.Body, seq.OutputText, seq.ReasoningText, false)
	m := computeintegrity.Measurement{ScoredTokens: result.ScoredTokens, Top1Matches: result.Top1Matches, SumLogprob: result.SumLogprob}
	// A known sequence was scored usably by two scorers before, so anything
	// but a usable answer counts toward the FR-24 silence back-off, exactly
	// as for an ordinary job; a short "ok" answer also fails the check.
	if !answered || result.Status != "ok" {
		e.scorers.RecordNoAnswer(scorer.ProviderID, e.s.now())
		return
	}
	if m.Valid() {
		e.scorers.RecordAnswer(scorer.ProviderID)
	} else {
		e.scorers.RecordNoAnswer(scorer.ProviderID, e.s.now())
	}
	if e.scorers.RecordKnownCheck(scorer.ProviderID, computeintegrity.KnownCheckPassed(seq, m)) {
		e.persistExclusion(ctx, scorer.ProviderID, e.s.now())
	}
}

func (e *computeScoringEngine) publishGauges(ctx context.Context) {
	if e.deps.Metrics == nil {
		return
	}
	counts := map[computeintegrity.VerificationState]int{}
	e.mu.Lock()
	for _, st := range e.states {
		counts[st.State]++
	}
	e.mu.Unlock()
	for _, state := range []computeintegrity.VerificationState{
		computeintegrity.VerificationUnverified, computeintegrity.VerificationPassing, computeintegrity.VerificationSuspect,
		computeintegrity.VerificationFailed, computeintegrity.VerificationRecovering,
	} {
		e.deps.Metrics.SetComputeIntegrityKeys(string(state), counts[state])
	}
	cctx, cancel := context.WithTimeout(ctx, computeScoreLookupTimeout)
	defer cancel()
	if n, err := e.deps.Holds.CountHeldComputeIntegrityHolds(cctx); err == nil {
		e.deps.Metrics.SetComputeIntegrityHeldHolds(n)
	}
}

func (s *Server) handleComputeScoreResult(providerID, assignedID string, payload []byte) {
	e := s.computeScoring.Load()
	if e == nil {
		return
	}
	result, field, err := ParseComputeScoreResult(payload)
	if err != nil {
		// field is a closed category; scorer-controlled text is never logged.
		s.log.Warn().Str("event", "compute_integrity_score_result_invalid").Str("field", field).Str("provider_id", providerID).Msg("invalid compute score result")
		return
	}
	now := s.now()
	e.pendingMu.Lock()
	pending := e.pending[result.ScoreID]
	if pending == nil ||
		pending.scorerID != providerID || pending.assignedID != assignedID ||
		result.ProviderID != providerID || result.AssignedID != assignedID ||
		result.ModelID != pending.modelID || result.WeightsManifestSHA256 != pending.manifest ||
		now.After(pending.deadline) {
		e.pendingMu.Unlock()
		s.log.Warn().Str("event", "compute_integrity_score_result_rejected").Str("provider_id", providerID).Msg("compute score result rejected: no matching live request")
		return
	}
	delete(e.pending, result.ScoreID)
	e.pendingMu.Unlock()
	select {
	case pending.ch <- result:
	default:
	}
}
