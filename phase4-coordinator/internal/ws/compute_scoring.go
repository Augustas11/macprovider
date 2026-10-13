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
	"encoding/json"
	"errors"
	"fmt"
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

// ParseComputeScoreResult strictly decodes an FR-21 result frame.
func ParseComputeScoreResult(payload []byte) (ComputeScoreResult, string, error) {
	if len(payload) > maxComputeScoreResultBytes {
		return ComputeScoreResult{}, "payload", fmt.Errorf("%s exceeds %d bytes", computeScoreResultType, maxComputeScoreResultBytes)
	}
	if field, err := rejectDuplicateJSONFields(payload); err != nil {
		return ComputeScoreResult{}, field, err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return ComputeScoreResult{}, "json", err
	}
	if field := rejectUnknownFields(raw, computeScoreResultFields); field != "" {
		return ComputeScoreResult{}, field, fmt.Errorf("unknown field %s", field)
	}
	var result ComputeScoreResult
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&result); err != nil {
		return ComputeScoreResult{}, "json", err
	}
	switch {
	case result.Type != computeScoreResultType:
		return ComputeScoreResult{}, "type", fmt.Errorf("unexpected type %q", result.Type)
	case result.Version != 1:
		return ComputeScoreResult{}, "version", fmt.Errorf("unsupported version %d", result.Version)
	case !boundedPrintable(result.ScoreID, 1, 128):
		return ComputeScoreResult{}, "score_id", errors.New("invalid score_id")
	case !boundedPrintable(result.ProviderID, 1, 256), !boundedPrintable(result.AssignedID, 1, 256), !boundedPrintable(result.ModelID, 1, 256):
		return ComputeScoreResult{}, "identity", errors.New("invalid identity")
	case !isLowerHex64(result.WeightsManifestSHA256):
		return ComputeScoreResult{}, "weights_manifest_sha256", errors.New("invalid manifest hash")
	}
	switch result.Status {
	case "ok", "unavailable", "invalid", "too_long":
	default:
		return ComputeScoreResult{}, "status", fmt.Errorf("unknown status %q", result.Status)
	}
	if result.PromptTokens < 0 || result.ScoredTokens < 0 || result.Top1Matches < 0 || result.Top1Matches > result.ScoredTokens {
		return ComputeScoreResult{}, "counts", errors.New("invalid counts")
	}
	return result, "", nil
}

// ComputeIntegrityProbeDispatch is one FR-20 verification request.
type ComputeIntegrityProbeDispatch struct {
	ProviderID string
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
// ordinary buyer dispatch path, pinned to one provider.
type ComputeIntegrityProbeDispatcher func(context.Context, ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error)

// ComputeIntegrityHoldStore is the SPEC-022 R-16 hold writer.
type ComputeIntegrityHoldStore interface {
	OpenComputeIntegrityHold(ctx context.Context, providerID, modelID string, kind computeintegrity.HoldKind, start time.Time, end *time.Time, reason string, now time.Time) (int64, error)
	CloseComputeIntegrityRecoveryHold(ctx context.Context, providerID, modelID string, end time.Time, release bool, now time.Time) error
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
	ch         chan ComputeScoreResult
}

type cachedOperatorKey struct {
	key     string
	fetched time.Time
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
// starts the FR-20 scheduler. It runs until ctx is done.
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
	return time.Duration(e.deps.Config.RecoveryCooldownMinutes) * time.Minute
}

func (e *computeScoringEngine) interval(state computeintegrity.VerificationState) time.Duration {
	if state.Escalating() {
		return time.Duration(e.deps.Config.EscalationIntervalMinutes) * time.Minute
	}
	return time.Duration(e.deps.Config.BaseIntervalMinutes) * time.Minute
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

func (e *computeScoringEngine) sweep(ctx context.Context, now time.Time) {
	if !e.deps.Config.Enabled || e.s.pool == nil {
		return
	}
	providers := e.s.pool.Snapshot()
	candidates := make([]computeintegrity.ScorerCandidate, 0, len(providers))
	for _, p := range providers {
		if p.ModelID == "" || p.WeightsManifestSHA256 == "" {
			continue
		}
		candidates = append(candidates, computeintegrity.ScorerCandidate{
			ProviderID:     p.ProviderID,
			AssignedID:     p.AssignedID,
			ModelID:        p.ModelID,
			ManifestSHA256: p.WeightsManifestSHA256,
			OperatorKey:    e.operatorKey(ctx, p.ProviderID, now),
			Capable:        p.ComputeScoreV1,
			Ready:          providerScoringReady(p),
		})
	}
	for _, p := range providers {
		if p.ModelID == "" || p.WeightsManifestSHA256 == "" || !providerScoringReady(p) {
			continue
		}
		e.considerProvider(ctx, p, candidates, now)
	}
	e.publishGauges(ctx)
}

func (e *computeScoringEngine) considerProvider(ctx context.Context, p pool.Provider, candidates []computeintegrity.ScorerCandidate, now time.Time) {
	key := computeScoringKey{p.ProviderID, p.ModelID}
	e.mu.Lock()
	st := e.stateLocked(key, now)
	before := *st
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
	go e.runProbe(ctx, p, verified, scorers)
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

func (e *computeScoringEngine) runProbe(ctx context.Context, p pool.Provider, verified computeintegrity.ScorerCandidate, scorers []computeintegrity.ScorerCandidate) {
	key := computeScoringKey{p.ProviderID, p.ModelID}
	defer e.finishProbe(key)
	sampledKey := computeintegrity.ToleranceKey{ModelID: p.ModelID, ManifestSHA256: verified.ManifestSHA256, Class: computeintegrity.SamplingSampled}
	e.mu.Lock()
	greedyOnly := false
	if st := e.states[key]; st != nil && st.State.Escalating() {
		greedyOnly = !e.tolerance.Band(sampledKey).Warm
	}
	probe, err := computeintegrity.DrawProbe(e.rng, e.deps.Corpus, p.ModelID, greedyOnly)
	e.mu.Unlock()
	if err != nil {
		e.inconclusive(ciInconclusiveDispatch)
		return
	}
	dctx, cancel := context.WithTimeout(ctx, computeScoreDispatchTimeout)
	defer cancel()
	resp, err := e.deps.Dispatch(dctx, ComputeIntegrityProbeDispatch{
		ProviderID: p.ProviderID,
		ModelID:    p.ModelID,
		Body:       probe.Body,
		MaxTokens:  probe.MaxTokens,
	})
	if err != nil || !resp.Complete || strings.TrimSpace(resp.OutputText+resp.ReasoningText) == "" {
		e.inconclusive(ciInconclusiveDispatch)
		return
	}
	measurements, reason := e.scoreAll(ctx, scorers, verified, probe.Body, resp.OutputText, resp.ReasoningText)
	if len(measurements) == 0 {
		e.inconclusive(reason)
		return
	}
	tkey := computeintegrity.ToleranceKey{ModelID: p.ModelID, ManifestSHA256: verified.ManifestSHA256, Class: probe.Class}
	e.decide(ctx, key, verified, tkey, measurements, computeintegrity.KnownSequence{
		Body:          probe.Body,
		OutputText:    resp.OutputText,
		ReasoningText: resp.ReasoningText,
	})
}

// scoreAll sends one scoring job per scorer and waits for every answer up to
// the FR-21 deadline. It returns the valid measurements, or the inconclusive
// reason when there are none.
func (e *computeScoringEngine) scoreAll(ctx context.Context, scorers []computeintegrity.ScorerCandidate, verified computeintegrity.ScorerCandidate, body []byte, output, reasoning string) ([]scoredMeasurement, string) {
	type answer struct {
		scorer computeintegrity.ScorerCandidate
		result ComputeScoreResult
		ok     bool
	}
	answers := make(chan answer, len(scorers))
	for _, sc := range scorers {
		go func(sc computeintegrity.ScorerCandidate) {
			result, ok := e.score(ctx, sc, verified.ManifestSHA256, body, output, reasoning)
			answers <- answer{scorer: sc, result: result, ok: ok}
		}(sc)
	}
	var out []scoredMeasurement
	reason := ciInconclusiveScorerTimeout
	for range scorers {
		a := <-answers
		if !a.ok {
			continue
		}
		if a.result.Status != "ok" {
			reason = ciInconclusiveScorerInvalid
			continue
		}
		m := computeintegrity.Measurement{ScoredTokens: a.result.ScoredTokens, Top1Matches: a.result.Top1Matches, SumLogprob: a.result.SumLogprob}
		if !m.Valid() {
			reason = ciInconclusiveShortOutput
			continue
		}
		out = append(out, scoredMeasurement{scorer: a.scorer, measurement: m})
	}
	return out, reason
}

// score runs one FR-21 job on one scorer.
func (e *computeScoringEngine) score(ctx context.Context, scorer computeintegrity.ScorerCandidate, manifest string, body []byte, output, reasoning string) (ComputeScoreResult, bool) {
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
	pending := &pendingComputeScore{scorerID: scorer.ProviderID, assignedID: scorer.AssignedID, modelID: scorer.ModelID, manifest: manifest, ch: make(chan ComputeScoreResult, 1)}
	e.mu.Lock()
	e.pending[scoreID] = pending
	e.scoringJobs++
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		delete(e.pending, scoreID)
		e.mu.Unlock()
	}()
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
	before := *st
	before.Escalations = append([]computeintegrity.EscalationEntry(nil), st.Escalations...)
	if tr := st.Apply(outcome); tr != nil {
		if !e.applyTransitionLocked(ctx, st, tr, now) {
			*st = before
		}
	} else if err := e.deps.Store.UpsertKeyState(ctx, st, now); err != nil {
		e.s.log.Warn().Err(err).Str("event", "compute_integrity_state_persist_failed").Msg("compute-integrity state not persisted")
	}
	jobs := e.scoringJobs
	e.mu.Unlock()

	if e.deps.Metrics != nil {
		switch {
		case allIn:
			e.deps.Metrics.IncComputeIntegrityVerification("in_band")
		case allOut:
			e.deps.Metrics.IncComputeIntegrityVerification("out_of_band")
		default:
			e.deps.Metrics.IncComputeIntegrityVerification("inconclusive")
			e.deps.Metrics.IncComputeIntegrityInconclusive("scorer_split")
		}
	}
	if jobs/computeintegrity.KnownSequenceCheckEvery != (jobs-len(ms))/computeintegrity.KnownSequenceCheckEvery {
		go e.knownSequenceCheck(ctx, tkey)
	}
}

// applyTransitionLocked writes the hold change, then the routing suspension,
// then persists the state. A failed hold write leaves the transition
// unapplied so the next measurement retries it; it returns false then.
// Caller holds mu.
func (e *computeScoringEngine) applyTransitionLocked(ctx context.Context, st *computeintegrity.KeyState, tr *computeintegrity.Transition, now time.Time) bool {
	if err := e.applyHold(ctx, st, tr, now); err != nil {
		e.s.log.Error().Err(err).
			Str("event", "compute_integrity_hold_write_failed").
			Str("provider_id", st.ProviderID).
			Str("model_id", st.ModelID).
			Str("to", string(tr.To)).
			Msg("compute-integrity transition deferred: hold write failed")
		return false
	}
	if e.s.pool != nil {
		e.s.pool.SetComputeIntegritySuspended(st.ProviderID, st.ModelID, tr.To.RoutingSuspended())
	}
	if err := e.deps.Store.UpsertKeyState(ctx, st, now); err != nil {
		e.s.log.Warn().Err(err).Str("event", "compute_integrity_state_persist_failed").Msg("compute-integrity state not persisted")
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

func (e *computeScoringEngine) applyHold(ctx context.Context, st *computeintegrity.KeyState, tr *computeintegrity.Transition, now time.Time) error {
	holds := e.deps.Holds
	switch tr.Hold.Kind {
	case computeintegrity.HoldActionNone:
		return nil
	case computeintegrity.HoldActionOpenFailure:
		end := tr.Hold.End
		_, err := holds.OpenComputeIntegrityHold(ctx, st.ProviderID, st.ModelID, computeintegrity.HoldKindFailure, tr.Hold.Start, &end, string(tr.Reason), now)
		return err
	case computeintegrity.HoldActionOpenRecovery:
		_, err := holds.OpenComputeIntegrityHold(ctx, st.ProviderID, st.ModelID, computeintegrity.HoldKindRecovery, tr.Hold.Start, nil, string(tr.Reason), now)
		return err
	case computeintegrity.HoldActionReleaseRecovery:
		return holds.CloseComputeIntegrityRecoveryHold(ctx, st.ProviderID, st.ModelID, tr.Hold.End, true, now)
	case computeintegrity.HoldActionCloseRecovery:
		return holds.CloseComputeIntegrityRecoveryHold(ctx, st.ProviderID, st.ModelID, tr.Hold.End, false, now)
	}
	return fmt.Errorf("unknown hold action %q", tr.Hold.Kind)
}

func (e *computeScoringEngine) persistExclusion(ctx context.Context, providerID string, now time.Time) {
	if err := e.deps.Store.ExcludeScorer(ctx, providerID, now); err != nil {
		e.s.log.Warn().Err(err).Str("event", "compute_integrity_scorer_exclusion_persist_failed").Msg("scorer exclusion not persisted")
		return
	}
	e.s.log.Warn().Str("event", "compute_integrity_scorer_excluded").Str("provider_id", providerID).Msg("compute-integrity scorer excluded")
}

// knownSequenceCheck sends one FR-24 known sequence to a random eligible
// scorer that did not score it originally.
func (e *computeScoringEngine) knownSequenceCheck(ctx context.Context, tkey computeintegrity.ToleranceKey) {
	var candidates []computeintegrity.ScorerCandidate
	for _, p := range e.s.pool.Snapshot() {
		if !p.ComputeScoreV1 || !providerScoringReady(p) || p.ModelID != tkey.ModelID || p.WeightsManifestSHA256 != tkey.ManifestSHA256 {
			continue
		}
		candidates = append(candidates, computeintegrity.ScorerCandidate{ProviderID: p.ProviderID, AssignedID: p.AssignedID, ModelID: p.ModelID, ManifestSHA256: p.WeightsManifestSHA256})
	}
	e.mu.Lock()
	var eligible []computeintegrity.ScorerCandidate
	for _, c := range candidates {
		if e.scorerEligibleLocked(c) {
			eligible = append(eligible, c)
		}
	}
	if len(eligible) == 0 {
		e.mu.Unlock()
		return
	}
	scorer := eligible[e.rng.Intn(len(eligible))]
	seq, ok := e.known.Pick(e.rng, tkey, scorer.ProviderID)
	e.mu.Unlock()
	if !ok {
		return
	}
	result, answered := e.score(ctx, scorer, tkey.ManifestSHA256, seq.Body, seq.OutputText, seq.ReasoningText)
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
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid compute score result")
		return
	}
	e.mu.Lock()
	pending := e.pending[result.ScoreID]
	if pending == nil ||
		pending.scorerID != providerID || pending.assignedID != assignedID ||
		result.ProviderID != providerID || result.AssignedID != assignedID ||
		result.ModelID != pending.modelID || result.WeightsManifestSHA256 != pending.manifest {
		e.mu.Unlock()
		s.log.Warn().Str("provider_id", providerID).Msg("compute score result rejected: no matching request")
		return
	}
	delete(e.pending, result.ScoreID)
	e.mu.Unlock()
	select {
	case pending.ch <- result:
	default:
	}
}
