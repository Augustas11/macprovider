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
	manifest   string
	deadline   time.Time
	ch         chan ComputeScoreResult
}

type cachedOperatorKey struct {
	key     string
	fetched time.Time
}

type scorerPoolKey struct {
	modelID  string
	manifest string
}

type computeScoringEngine struct {
	s    *Server
	deps ComputeScoringDeps

	tolerance *computeintegrity.Tolerance
	scorers   *computeintegrity.ScorerTracker
	known     *computeintegrity.KnownSequences

	mu            sync.Mutex
	rng           *rand.Rand
	states        map[computeScoringKey]*computeintegrity.KeyState
	nextDue       map[computeScoringKey]time.Time
	inFlight      map[computeScoringKey]bool
	inFlightCount int
	hourStart     time.Time
	hourCount     int
	scoringJobs   int
	pending       map[string]*pendingComputeScore
	operatorKeys  map[string]cachedOperatorKey
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
		inFlight:     map[computeScoringKey]bool{},
		pending:      map[string]*pendingComputeScore{},
		operatorKeys: map[string]cachedOperatorKey{},
	}
	for _, st := range states {
		st.RecoveryCooldown = e.recoveryCooldown()
		e.states[computeScoringKey{st.ProviderID, st.ModelID}] = st
		if st.State.RoutingSuspended() && s.pool != nil {
			s.pool.SetComputeIntegritySuspended(st.ProviderID, st.ModelID, true)
		}
	}
	s.computeScoring.Store(e)
	return e, nil
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

func (e *computeScoringEngine) run(ctx context.Context) {
	sweep := time.Duration(e.deps.Config.SweepIntervalSeconds) * time.Second
	if sweep <= 0 {
		sweep = 30 * time.Second
	}
	ticker := time.NewTicker(sweep)
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
	if ok && now.Sub(cached.fetched) < computeScoreOperatorTTL {
		return cached.key
	}
	key, err := e.deps.OperatorKey(ctx, providerID)
	if err != nil || key == "" {
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
	return p.ModelID != "" && isLowerHex64(p.WeightsManifestSHA256) && p.HashStatus == pool.HashStatusVerified && providerScoringReady(p)
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
	providers := e.s.pool.Snapshot()
	present := make(map[string]struct{}, len(providers))
	for _, p := range providers {
		present[p.ProviderID] = struct{}{}
	}
	e.prune(present)
	if !e.deps.Config.Enabled {
		e.publishGauges(ctx)
		return
	}
	// One scorer index per sweep, keyed by (model, manifest), so selection
	// costs the size of one model's pool rather than the whole fleet.
	index := map[scorerPoolKey][]computeintegrity.ScorerCandidate{}
	for _, p := range providers {
		if !providerVerifiable(p) {
			continue
		}
		k := scorerPoolKey{p.ModelID, p.WeightsManifestSHA256}
		index[k] = append(index[k], computeintegrity.ScorerCandidate{
			ProviderID:     p.ProviderID,
			AssignedID:     p.AssignedID,
			ModelID:        p.ModelID,
			ManifestSHA256: p.WeightsManifestSHA256,
			OperatorKey:    e.operatorKey(ctx, p.ProviderID, now),
			Capable:        p.ComputeScoreV1,
			Ready:          true,
		})
	}
	for _, p := range providers {
		if !providerVerifiable(p) {
			continue
		}
		e.considerProvider(ctx, p, index[scorerPoolKey{p.ModelID, p.WeightsManifestSHA256}], now)
	}
	e.publishGauges(ctx)
}

// prune drops schedule and cache entries of providers that left the pool.
// Key states stay: a failed key must survive a disconnect.
func (e *computeScoringEngine) prune(present map[string]struct{}) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for key := range e.nextDue {
		if _, ok := present[key.providerID]; !ok && !e.inFlight[key] {
			delete(e.nextDue, key)
		}
	}
	for id := range e.operatorKeys {
		if _, ok := present[id]; !ok {
			delete(e.operatorKeys, id)
		}
	}
}

func (e *computeScoringEngine) considerProvider(ctx context.Context, p pool.Provider, candidates []computeintegrity.ScorerCandidate, now time.Time) {
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
		// Spread first requests over one interval so a restart does not
		// probe the whole fleet at once.
		e.nextDue[key] = now.Add(time.Duration(e.rng.Float64() * float64(e.interval(st.State))))
		e.mu.Unlock()
		return
	}
	if now.Before(due) || !p.RoutingEligible() {
		e.mu.Unlock()
		return
	}
	if now.Sub(e.hourStart) >= time.Hour {
		e.hourStart = now
		e.hourCount = 0
	}
	if e.inFlightCount >= e.deps.Config.MaxInFlight || e.hourCount >= e.deps.Config.MaxPerHour {
		e.mu.Unlock()
		return
	}
	state := st.State
	e.mu.Unlock()

	verified := computeintegrity.ScorerCandidate{
		ProviderID:     p.ProviderID,
		AssignedID:     p.AssignedID,
		ModelID:        p.ModelID,
		ManifestSHA256: p.WeightsManifestSHA256,
		OperatorKey:    e.operatorKey(ctx, p.ProviderID, now),
	}
	if verified.OperatorKey == "" {
		return
	}
	n := 1
	if state.Escalating() {
		n = 2
	}
	e.mu.Lock()
	scorers := computeintegrity.SelectScorers(e.rng, verified, candidates, n, e.scorerEligibleLocked)
	if len(scorers) == 0 {
		e.nextDue[key] = now.Add(e.jitter(e.interval(state)))
		e.mu.Unlock()
		e.inconclusive(ciInconclusiveNoScorer)
		return
	}
	e.inFlight[key] = true
	e.inFlightCount++
	e.hourCount++
	e.mu.Unlock()
	go e.runProbe(ctx, verified, scorers)
}

// scorerEligibleLocked applies FR-21 rule 4. Caller holds mu.
func (e *computeScoringEngine) scorerEligibleLocked(c computeintegrity.ScorerCandidate) bool {
	if e.scorers.Excluded(c.ProviderID) {
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
	e.nextDue[key] = now.Add(e.jitter(e.interval(state)))
}

type scoredMeasurement struct {
	scorer      computeintegrity.ScorerCandidate
	measurement computeintegrity.Measurement
}

// sessionUnchanged reports whether the verified session still serves the
// same model and manifest it was selected with (FR-20 output binding).
func (e *computeScoringEngine) sessionUnchanged(verified computeintegrity.ScorerCandidate) bool {
	p, ok := e.s.pool.Resolve(verified.ProviderID, verified.AssignedID)
	return ok && p.ModelID == verified.ModelID && p.WeightsManifestSHA256 == verified.ManifestSHA256
}

func (e *computeScoringEngine) runProbe(ctx context.Context, verified computeintegrity.ScorerCandidate, scorers []computeintegrity.ScorerCandidate) {
	key := computeScoringKey{verified.ProviderID, verified.ModelID}
	defer e.finishProbe(key)
	sampledKey := computeintegrity.ToleranceKey{ModelID: verified.ModelID, ManifestSHA256: verified.ManifestSHA256, Class: computeintegrity.SamplingSampled}
	e.mu.Lock()
	greedyOnly := false
	if st := e.states[key]; st != nil && st.State.Escalating() {
		greedyOnly = !e.tolerance.Band(sampledKey).Warm
	}
	probe, err := computeintegrity.DrawProbe(e.rng, e.deps.Corpus, verified.ModelID, greedyOnly)
	e.mu.Unlock()
	if err != nil {
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
			result, ok := e.score(ctx, sc, verified.ManifestSHA256, body, output, reasoning, true)
			answers <- answer{scorer: sc, result: result, ok: ok}
		}(sc)
	}
	var out []scoredMeasurement
	reason := ""
	for range scorers {
		a := <-answers
		switch {
		case !a.ok:
			if reason == "" {
				reason = ciInconclusiveScorerTimeout
			}
		case a.result.Status != "ok":
			if reason == "" {
				reason = ciInconclusiveScorerInvalid
			}
		default:
			m := computeintegrity.Measurement{ScoredTokens: a.result.ScoredTokens, Top1Matches: a.result.Top1Matches, SumLogprob: a.result.SumLogprob}
			if !m.Valid() {
				if reason == "" {
					reason = ciInconclusiveShortOutput
				}
				continue
			}
			out = append(out, scoredMeasurement{scorer: a.scorer, measurement: m})
		}
	}
	return out, reason, len(out) == len(scorers) && len(out) > 0
}

// score runs one FR-21 job on one scorer. countJob marks an ordinary scoring
// job, which advances the FR-24 known-sequence cadence.
func (e *computeScoringEngine) score(ctx context.Context, scorer computeintegrity.ScorerCandidate, manifest string, body []byte, output, reasoning string, countJob bool) (ComputeScoreResult, bool) {
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
	checkKnown := false
	e.mu.Lock()
	e.pending[scoreID] = pending
	if countJob {
		e.scoringJobs++
		checkKnown = e.scoringJobs%computeintegrity.KnownSequenceCheckEvery == 0
	}
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		delete(e.pending, scoreID)
		e.mu.Unlock()
	}()
	if checkKnown {
		go e.knownSequenceCheck(ctx, computeintegrity.ToleranceKey{ModelID: scorer.ModelID, ManifestSHA256: manifest})
	}
	if err := session.send(raw); err != nil {
		e.scoringJobMetric("timeout")
		return ComputeScoreResult{}, false
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
		if allIn {
			seq.Scorers = []string{ms[0].scorer.ProviderID, ms[1].scorer.ProviderID}
			e.known.Offer(tkey, seq, ms[0].measurement, ms[1].measurement)
		}
	}
	outcome := computeintegrity.Outcome{InBand: allIn, OutOfBand: allOut, OutReason: outReason, ScorerOperators: ops, At: now}

	e.mu.Lock()
	st := e.stateLocked(key, now)
	if allIn && st.State.AcceptsHonestSamples() {
		e.tolerance.Accept(tkey, verified.OperatorKey, ms[0].measurement)
	}
	before := cloneKeyState(st)
	if tr := st.Apply(outcome); tr != nil {
		if !e.applyTransitionLocked(ctx, st, tr, now) {
			*st = before
		}
	} else if err := e.deps.Store.UpsertKeyState(ctx, st, now); err != nil {
		e.s.log.Warn().Str("event", "compute_integrity_state_persist_failed").Msg("compute-integrity state not persisted")
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

func (e *computeScoringEngine) persistExclusion(ctx context.Context, providerID string, now time.Time) {
	if err := e.deps.Store.ExcludeScorer(ctx, providerID, now); err != nil {
		e.s.log.Warn().Str("event", "compute_integrity_scorer_exclusion_persist_failed").Str("provider_id", providerID).Msg("scorer exclusion not persisted")
		return
	}
	e.s.log.Warn().Str("event", "compute_integrity_scorer_excluded").Str("provider_id", providerID).Msg("compute-integrity scorer excluded")
}

// knownSequenceCheck sends one FR-24 known sequence of the model to a random
// eligible scorer that did not score it originally. tkey names the model and
// manifest; every sampling class is eligible.
func (e *computeScoringEngine) knownSequenceCheck(ctx context.Context, tkey computeintegrity.ToleranceKey) {
	var candidates []computeintegrity.ScorerCandidate
	for _, p := range e.s.pool.Snapshot() {
		if !p.ComputeScoreV1 || !providerVerifiable(p) || p.ModelID != tkey.ModelID || p.WeightsManifestSHA256 != tkey.ManifestSHA256 {
			continue
		}
		candidates = append(candidates, computeintegrity.ScorerCandidate{ProviderID: p.ProviderID, AssignedID: p.AssignedID, ModelID: p.ModelID, ManifestSHA256: p.WeightsManifestSHA256})
	}
	e.mu.Lock()
	e.rng.Shuffle(len(candidates), func(i, j int) { candidates[i], candidates[j] = candidates[j], candidates[i] })
	var scorer computeintegrity.ScorerCandidate
	var seq computeintegrity.KnownSequence
	found := false
	for _, c := range candidates {
		if !e.scorerEligibleLocked(c) {
			continue
		}
		for _, class := range []computeintegrity.SamplingClass{computeintegrity.SamplingGreedy, computeintegrity.SamplingSampled} {
			k := tkey
			k.Class = class
			if s, ok := e.known.Pick(e.rng, k, c.ProviderID); ok {
				scorer, seq, found = c, s, true
				break
			}
		}
		if found {
			break
		}
	}
	e.mu.Unlock()
	if !found {
		return
	}
	result, answered := e.score(ctx, scorer, tkey.ManifestSHA256, seq.Body, seq.OutputText, seq.ReasoningText, false)
	if !answered || result.Status != "ok" {
		return
	}
	m := computeintegrity.Measurement{ScoredTokens: result.ScoredTokens, Top1Matches: result.Top1Matches, SumLogprob: result.SumLogprob}
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
	if n, err := e.deps.Holds.CountHeldComputeIntegrityHolds(ctx); err == nil {
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
	e.mu.Lock()
	pending := e.pending[result.ScoreID]
	if pending == nil ||
		pending.scorerID != providerID || pending.assignedID != assignedID ||
		result.ProviderID != providerID || result.AssignedID != assignedID ||
		result.ModelID != pending.modelID || result.WeightsManifestSHA256 != pending.manifest ||
		now.After(pending.deadline) {
		e.mu.Unlock()
		s.log.Warn().Str("event", "compute_integrity_score_result_rejected").Str("provider_id", providerID).Msg("compute score result rejected: no matching live request")
		return
	}
	delete(e.pending, result.ScoreID)
	e.mu.Unlock()
	select {
	case pending.ch <- result:
	default:
	}
}
