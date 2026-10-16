package ws

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type fakeHold struct {
	computeintegrity.EarningsHold
}

type fakeHoldStore struct {
	mu       sync.Mutex
	holds    []*fakeHold
	fail     atomic.Bool
	attempts atomic.Int64
	// breakStateWrite makes the state write of the same transaction fail
	// (the rename is rolled back with it).
	breakStateWrite atomic.Bool
}

func (f *fakeHoldStore) ApplyComputeIntegrityHoldAction(ctx context.Context, tx *sql.Tx, providerID, modelID string, action computeintegrity.HoldAction, reason string, now time.Time) error {
	if tx == nil {
		return errors.New("hold action outside a transaction")
	}
	if action.Kind == computeintegrity.HoldActionNone {
		return nil
	}
	// The durable side of the fake lives in the transaction, so a rolled-back
	// transition leaves no hold row behind.
	if _, err := tx.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS fake_hold_log (provider_id TEXT, action TEXT)`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO fake_hold_log VALUES (?, ?)`, providerID, string(action.Kind)); err != nil {
		return err
	}
	if f.breakStateWrite.Load() {
		f.attempts.Add(1)
		_, err := tx.ExecContext(ctx, `ALTER TABLE compute_integrity_scoring_keys RENAME TO compute_integrity_scoring_keys_off`)
		return err
	}
	switch action.Kind {
	case computeintegrity.HoldActionOpenFailure:
		end := action.End
		_, err := f.OpenComputeIntegrityHold(ctx, providerID, modelID, computeintegrity.HoldKindFailure, action.Start, &end, reason, now)
		return err
	case computeintegrity.HoldActionOpenRecovery:
		_, err := f.OpenComputeIntegrityHold(ctx, providerID, modelID, computeintegrity.HoldKindRecovery, action.Start, nil, reason, now)
		return err
	case computeintegrity.HoldActionReleaseRecovery:
		return f.CloseComputeIntegrityRecoveryHold(ctx, providerID, modelID, action.End, true, now)
	case computeintegrity.HoldActionCloseRecovery:
		return f.CloseComputeIntegrityRecoveryHold(ctx, providerID, modelID, action.End, false, now)
	}
	return errors.New("unknown hold action")
}

func (f *fakeHoldStore) OpenComputeIntegrityHold(_ context.Context, providerID, modelID string, kind computeintegrity.HoldKind, start time.Time, end *time.Time, reason string, now time.Time) (int64, error) {
	f.attempts.Add(1)
	if f.fail.Load() {
		return 0, errors.New("hold store down")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	h := &fakeHold{computeintegrity.EarningsHold{
		ID: int64(len(f.holds) + 1), ProviderID: providerID, ModelID: modelID, Kind: kind,
		WindowStart: start, WindowEnd: end, Reason: reason, Status: computeintegrity.HoldHeld, CreatedAt: now,
	}}
	f.holds = append(f.holds, h)
	return h.ID, nil
}

func (f *fakeHoldStore) CloseComputeIntegrityRecoveryHold(_ context.Context, providerID, modelID string, end time.Time, release bool, now time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, h := range f.holds {
		if h.ProviderID == providerID && h.ModelID == modelID && h.Kind == computeintegrity.HoldKindRecovery && h.WindowEnd == nil {
			e := end
			h.WindowEnd = &e
			if release {
				h.Status = computeintegrity.HoldReleased
				h.ReleasedAt = &now
			}
		}
	}
	return nil
}

func (f *fakeHoldStore) ComputeIntegrityHolds(_ context.Context, providerID string) ([]computeintegrity.EarningsHold, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []computeintegrity.EarningsHold
	for _, h := range f.holds {
		if h.ProviderID == providerID {
			out = append(out, h.EarningsHold)
		}
	}
	return out, nil
}

func (f *fakeHoldStore) ReleaseComputeIntegrityHold(_ context.Context, holdID int64, operatorID, reason string, now time.Time) (computeintegrity.EarningsHold, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, h := range f.holds {
		if h.ID == holdID {
			if h.Status != computeintegrity.HoldHeld {
				return h.EarningsHold, computeintegrity.ErrHoldAlreadyReleased
			}
			h.Status = computeintegrity.HoldReleased
			h.ReleasedBy = operatorID
			h.ReleaseReason = reason
			h.ReleasedAt = &now
			return h.EarningsHold, nil
		}
	}
	return computeintegrity.EarningsHold{}, computeintegrity.ErrHoldNotFound
}

func (f *fakeHoldStore) CountHeldComputeIntegrityHolds(context.Context) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, h := range f.holds {
		if h.Status == computeintegrity.HoldHeld {
			n++
		}
	}
	return n, nil
}

func (f *fakeHoldStore) snapshot() []computeintegrity.EarningsHold {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []computeintegrity.EarningsHold
	for _, h := range f.holds {
		out = append(out, h.EarningsHold)
	}
	return out
}

type scoringHarness struct {
	t          *testing.T
	server     *Server
	registry   *pool.Registry
	engine     *computeScoringEngine
	holds      *fakeHoldStore
	clock      atomic.Int64
	dispatched atomic.Int64
	cheatProbe atomic.Int64
	cheaters   map[string]bool
	conns      []net.Conn
	logs       *lockedBuffer
	db         *sql.DB
	silent     sync.Map
	short      sync.Map
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

const scoringModel = "model-ci"

var scoringManifest = strings.Repeat("d", 64)

var scoringModelHash = strings.Repeat("e", 64)

func (h *scoringHarness) now() time.Time { return time.Unix(0, h.clock.Load()).UTC() }

func (h *scoringHarness) advance(d time.Duration) { h.clock.Add(int64(d)) }

func newScoringHarness(t *testing.T, providers map[string]string, cheaters map[string]bool) *scoringHarness {
	t.Helper()
	h := &scoringHarness{t: t, registry: pool.NewRegistry(nil), holds: &fakeHoldStore{}, cheaters: cheaters, logs: &lockedBuffer{}}
	h.clock.Store(time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC).UnixNano())
	cfg := config.Default()
	cfg.Auth.OperatorKey = "op-key"
	h.server = NewServer(cfg, h.registry, zerolog.New(h.logs), WithNow(h.now))
	for id := range providers {
		p := &pool.Provider{
			ProviderID: id, AssignedID: "as-" + id, ModelID: scoringModel,
			ModelHash: scoringModelHash, WeightsManifestSHA256: scoringManifest, State: pool.StateReady,
			SlotsFree: 4, SlotsTotal: 4, MaxContextTokens: 8192, ComputeScoreV1: true,
			HashStatus: pool.HashStatusVerified,
		}
		client, server := net.Pipe()
		h.conns = append(h.conns, client, server)
		h.registry.Register(p, server)
		session := newProviderSession(p.ProviderID, p.AssignedID, server, 16, time.Second)
		h.server.sessions.Store(sessionKey(p.ProviderID, p.AssignedID), session)
		go session.runWriter()
		go h.fakeScorer(p.ProviderID, p.AssignedID, client)
	}
	t.Cleanup(func() {
		for _, c := range h.conns {
			_ = c.Close()
		}
	})
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "ci.db")+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	h.db = db
	store, err := computeintegrity.NewScoringStore(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	scfg := config.DefaultComputeIntegrityConfig().Scoring
	scfg.BaseIntervalSeconds = 3600
	scfg.EscalationIntervalSeconds = 600
	scfg.MaxInFlight = 16
	scfg.ScoreDeadlineSeconds = 5
	h.engine, err = h.server.newComputeScoringEngine(context.Background(), ComputeScoringDeps{
		Config: scfg,
		Store:  store,
		Dispatch: func(_ context.Context, d ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error) {
			h.dispatched.Add(1)
			var body map[string]any
			if err := json.Unmarshal(d.Body, &body); err != nil || body["model"] != scoringModel {
				return ComputeIntegrityProbeResponse{}, errors.New("bad body")
			}
			if h.cheaters[d.ProviderID] {
				h.cheatProbe.Add(1)
				return ComputeIntegrityProbeResponse{OutputText: "CHEAP output", Complete: true}, nil
			}
			return ComputeIntegrityProbeResponse{OutputText: "HONEST output", Complete: true}, nil
		},
		OperatorKey: func(_ context.Context, providerID string) (string, error) { return providers[providerID], nil },
		Holds:       h.holds,
		Rand:        rand.New(rand.NewSource(1644)),
	})
	if err != nil {
		t.Fatal(err)
	}
	h.engine.dispatchDelay = func() time.Duration { return 0 }
	return h
}

// fakeScorer answers every scoring job: an honest output scores near the
// generating model, a substituted one far below.
func (h *scoringHarness) fakeScorer(providerID, assignedID string, conn net.Conn) {
	for {
		raw, err := wsutil.ReadServerText(conn)
		if err != nil {
			return
		}
		var req ComputeScoreRequest
		if json.Unmarshal(raw, &req) != nil || req.Type != computeScoreRequestType {
			continue
		}
		if _, quiet := h.silent.Load(providerID); quiet {
			continue
		}
		result := ComputeScoreResult{
			Type: computeScoreResultType, Version: 1, ScoreID: req.ScoreID,
			ProviderID: req.ProviderID, AssignedID: req.AssignedID, ModelID: req.ModelID,
			WeightsManifestSHA256: req.WeightsManifestSHA256, Status: "ok",
			PromptTokens: 40, ScoredTokens: 100, Top1Matches: 98, SumLogprob: -18,
		}
		if strings.Contains(req.OutputText, "CHEAP") {
			result.Top1Matches = 55
			result.SumLogprob = -160
		}
		if _, short := h.short.Load(providerID); short {
			result.ScoredTokens, result.Top1Matches, result.SumLogprob = 4, 4, -1
		}
		payload, _ := json.Marshal(result)
		h.server.handleComputeScoreResult(providerID, assignedID, payload)
	}
}

func (h *scoringHarness) round(step time.Duration) {
	h.t.Helper()
	h.advance(step)
	h.engine.sweep(context.Background(), h.now())
	deadline := time.Now().Add(10 * time.Second)
	for {
		h.engine.mu.Lock()
		n := h.engine.inFlightCount
		h.engine.mu.Unlock()
		if n == 0 {
			return
		}
		if time.Now().After(deadline) {
			h.t.Fatal("probes did not finish")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (h *scoringHarness) state(providerID string) computeintegrity.VerificationState {
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	st := h.engine.states[computeScoringKey{providerID, scoringModel}]
	if st == nil {
		return ""
	}
	return st.State
}

func TestComputeScoringHonestProvidersPassAndCheaterFailsWithHold(t *testing.T) {
	providers := map[string]string{
		"honest": "github:1", "cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4",
	}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 12 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(2 * time.Hour)
		if h.state("cheat") == computeintegrity.VerificationSuspect {
			// Escalation cadence.
			for j := 0; j < 8 && h.state("cheat") == computeintegrity.VerificationSuspect; j++ {
				h.round(20 * time.Minute)
			}
		}
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationFailed {
		t.Fatalf("cheater state = %s, want failed", got)
	}
	cheat, ok := h.registry.Resolve("cheat", "as-cheat")
	if !ok || !cheat.ComputeIntegritySuspended || cheat.RoutingEligible() {
		t.Fatalf("failed provider must leave routing: suspended=%v eligible=%v", cheat.ComputeIntegritySuspended, cheat.RoutingEligible())
	}
	honest, _ := h.registry.Resolve("honest", "as-honest")
	if honest.ComputeIntegritySuspended || !honest.RoutingEligible() {
		t.Fatal("honest provider must stay routable")
	}
	holds := h.holds.snapshot()
	if len(holds) != 1 || holds[0].ProviderID != "cheat" || holds[0].Kind != computeintegrity.HoldKindFailure ||
		holds[0].Status != computeintegrity.HoldHeld || holds[0].WindowEnd == nil || !holds[0].WindowStart.Before(*holds[0].WindowEnd) {
		t.Fatalf("expected one held failure hold for the cheater, got %+v", holds)
	}

	// A failed key is not probed while suspended; the others still are.
	cheatBefore, allBefore := h.cheatProbe.Load(), h.dispatched.Load()
	for i := 0; i < 4; i++ {
		h.round(2 * time.Hour)
	}
	if h.cheatProbe.Load() != cheatBefore {
		t.Fatal("a failed key must not be probed during its cooldown")
	}
	if h.dispatched.Load() == allBefore {
		t.Fatal("other providers must keep being probed")
	}
	for i := 0; i < 8; i++ {
		h.round(2 * time.Hour)
	}
	for _, id := range []string{"honest", "scorer-a", "scorer-b"} {
		if got := h.state(id); got != computeintegrity.VerificationPassing {
			t.Fatalf("%s state = %s, want passing", id, got)
		}
	}

	// After the cooldown the cheater recovers onto probation with an open
	// recovery hold, keeps cheating, and fails again; the recovery hold
	// closes and stays held.
	h.round(25 * time.Hour)
	if got := h.state("cheat"); got != computeintegrity.VerificationRecovering && got != computeintegrity.VerificationFailed {
		t.Fatalf("after cooldown state = %s", got)
	}
	for j := 0; j < 12 && h.state("cheat") == computeintegrity.VerificationRecovering; j++ {
		h.round(20 * time.Minute)
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationFailed {
		t.Fatalf("persistent cheater must fail again, got %s", got)
	}
	holds = h.holds.snapshot()
	if len(holds) != 2 || holds[1].Kind != computeintegrity.HoldKindRecovery || holds[1].WindowEnd == nil || holds[1].Status != computeintegrity.HoldHeld {
		t.Fatalf("recovery hold must close and stay held: %+v", holds)
	}
}

func TestComputeScoringHoldWriteFailureDefersFailure(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	h.holds.fail.Store(true)
	for i := 0; i < 120 && h.holds.attempts.Load() < 2; i++ {
		h.round(20 * time.Minute)
	}
	if h.holds.attempts.Load() < 2 {
		t.Fatal("setup: the failure transition was never attempted")
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationSuspect {
		t.Fatalf("a failure must not apply while its hold cannot be written, state %s", got)
	}
	if p, _ := h.registry.Resolve("cheat", "as-cheat"); p.ComputeIntegritySuspended {
		t.Fatal("no suspension without the hold")
	}
	h.holds.fail.Store(false)
	for i := 0; i < 10 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationFailed {
		t.Fatalf("failure must apply once the hold store recovers, got %s", got)
	}
}

func TestComputeScoringNeedsScorerOfAnotherOperator(t *testing.T) {
	// Every connected provider belongs to one operator: nobody may score.
	providers := map[string]string{"a": "github:1", "b": "github:1"}
	h := newScoringHarness(t, providers, nil)
	for i := 0; i < 4; i++ {
		h.round(2 * time.Hour)
	}
	if n := h.dispatched.Load(); n != 0 {
		t.Fatalf("no verification request may be dispatched without an independent scorer, got %d", n)
	}
}

func TestComputeScoringPersistedFailureSuspendsOnStart(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 120 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
	}
	if h.state("cheat") != computeintegrity.VerificationFailed {
		t.Fatal("setup: expected failure")
	}
	// A fresh registry and engine over the same store re-apply the suspension.
	registry := pool.NewRegistry(nil)
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	registry.Register(&pool.Provider{ProviderID: "cheat", AssignedID: "as-2", ModelID: scoringModel, WeightsManifestSHA256: scoringManifest, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, HashStatus: pool.HashStatusVerified}, server)
	s2 := NewServer(config.Default(), registry, zerolog.Nop(), WithNow(h.now))
	if _, err := s2.newComputeScoringEngine(context.Background(), ComputeScoringDeps{
		Config: h.engine.deps.Config, Store: h.engine.deps.Store, Dispatch: h.engine.deps.Dispatch,
		OperatorKey: h.engine.deps.OperatorKey, Holds: h.holds,
	}); err != nil {
		t.Fatal(err)
	}
	if p, _ := registry.Resolve("cheat", "as-2"); !p.ComputeIntegritySuspended || p.RoutingEligible() {
		t.Fatal("a persisted failure must suspend routing after restart")
	}
}

func TestParseComputeScoreResultIsStrict(t *testing.T) {
	good := ComputeScoreResult{
		Type: computeScoreResultType, Version: 1, ScoreID: "s", ProviderID: "p", AssignedID: "a", ModelID: "m",
		WeightsManifestSHA256: scoringManifest, Status: "ok", ScoredTokens: 20, Top1Matches: 19, SumLogprob: -3,
	}
	raw, _ := json.Marshal(good)
	if _, _, err := ParseComputeScoreResult(raw); err != nil {
		t.Fatalf("valid result rejected: %v", err)
	}
	for name, mutate := range map[string]func(map[string]any){
		"unknown field":   func(m map[string]any) { m["prompt"] = "x" },
		"bad status":      func(m map[string]any) { m["status"] = "great" },
		"matches>scored":  func(m map[string]any) { m["top1_matches"] = 21 },
		"bad manifest":    func(m map[string]any) { m["weights_manifest_sha256"] = "AB" },
		"wrong type":      func(m map[string]any) { m["type"] = "compute_score_request_v1" },
		"control in id":   func(m map[string]any) { m["score_id"] = "a\nb" },
		"negative counts": func(m map[string]any) { m["scored_tokens"] = -1 },
	} {
		var m map[string]any
		_ = json.Unmarshal(raw, &m)
		mutate(m)
		bad, _ := json.Marshal(m)
		if _, _, err := ParseComputeScoreResult(bad); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

func TestComputeScoreResultFromWrongSessionIsIgnored(t *testing.T) {
	providers := map[string]string{"x": "github:1"}
	h := newScoringHarness(t, providers, nil)
	ch := make(chan ComputeScoreResult, 1)
	h.engine.mu.Lock()
	h.engine.pending["score-1"] = &pendingComputeScore{scorerID: "x", assignedID: "as-x", modelID: scoringModel, manifest: scoringManifest, deadline: h.now().Add(time.Minute), ch: ch}
	expired := make(chan ComputeScoreResult, 1)
	h.engine.pending["score-old"] = &pendingComputeScore{scorerID: "x", assignedID: "as-x", modelID: scoringModel, manifest: scoringManifest, deadline: h.now().Add(-time.Second), ch: expired}
	h.engine.mu.Unlock()
	result := ComputeScoreResult{
		Type: computeScoreResultType, Version: 1, ScoreID: "score-1", ProviderID: "x", AssignedID: "as-other", ModelID: scoringModel,
		WeightsManifestSHA256: scoringManifest, Status: "ok", ScoredTokens: 20, Top1Matches: 20,
	}
	raw, _ := json.Marshal(result)
	h.server.handleComputeScoreResult("x", "as-other", raw)
	select {
	case <-ch:
		t.Fatal("a result from another session must not be delivered")
	default:
	}
	result.AssignedID = "as-x"
	raw, _ = json.Marshal(result)
	h.server.handleComputeScoreResult("x", "as-x", raw)
	select {
	case got := <-ch:
		if got.ScoreID != "score-1" {
			t.Fatalf("unexpected result %+v", got)
		}
	default:
		t.Fatal("matching result must be delivered")
	}
	result.ScoreID = "score-old"
	raw, _ = json.Marshal(result)
	h.server.handleComputeScoreResult("x", "as-x", raw)
	select {
	case <-expired:
		t.Fatal("a result after its deadline must not be delivered")
	default:
	}
}

func (h *scoringHarness) admin(method, path string, body string) (int, map[string]any) {
	h.t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	req.Header.Set("Authorization", "Bearer op-key")
	rec := httptest.NewRecorder()
	h.server.handleAdminComputeIntegrity(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

// SPEC-036 FR-25: operators see state and holds, release a hold, and clear a
// failed key, which lifts its routing suspension; every action needs an
// operator id and a reason.
func TestComputeScoringOperatorStatusReleaseAndClear(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 120 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
	}
	if h.state("cheat") != computeintegrity.VerificationFailed {
		t.Fatal("setup: expected failure")
	}
	code, body := h.admin(http.MethodGet, "/admin/compute-integrity/cheat", "")
	if code != http.StatusOK {
		t.Fatalf("status GET code=%d body=%v", code, body)
	}
	scoring := body["scoring"].(map[string]any)
	models := scoring["models"].([]any)
	model := models[0].(map[string]any)
	if model["state"] != "failed" || model["reason"] != "confirmed_failure" || !strings.HasPrefix(model["next_step"].(string), "cooldown_until:") {
		t.Fatalf("unexpected model status %v", model)
	}
	holds := scoring["holds"].([]any)
	if len(holds) != 1 || holds[0].(map[string]any)["status"] != "held" {
		t.Fatalf("expected one held hold, got %v", holds)
	}
	raw, _ := json.Marshal(body)
	if strings.Contains(string(raw), "HONEST") || strings.Contains(string(raw), "CHEAP") {
		t.Fatal("status must never carry probe outputs")
	}

	if code, _ := h.admin(http.MethodPost, "/admin/compute-integrity/holds/1/release", `{"operator_id":"op","reason":""}`); code != http.StatusUnprocessableEntity {
		t.Fatalf("release without reason code=%d", code)
	}
	if code, _ := h.admin(http.MethodPost, "/admin/compute-integrity/holds/1/release", `{"operator_id":"op","reason":"reviewed","extra":1}`); code != http.StatusBadRequest {
		t.Fatalf("unknown field code=%d", code)
	}
	if code, out := h.admin(http.MethodPost, "/admin/compute-integrity/holds/1/release", `{"operator_id":"op","reason":"reviewed"}`); code != http.StatusOK {
		t.Fatalf("release code=%d body=%v", code, out)
	}
	if code, _ := h.admin(http.MethodPost, "/admin/compute-integrity/holds/1/release", `{"operator_id":"op","reason":"again"}`); code != http.StatusConflict {
		t.Fatalf("double release code=%d", code)
	}
	if code, _ := h.admin(http.MethodPost, "/admin/compute-integrity/holds/77/release", `{"operator_id":"op","reason":"x"}`); code != http.StatusNotFound {
		t.Fatalf("missing hold code=%d", code)
	}

	if code, out := h.admin(http.MethodPost, "/admin/compute-integrity/cheat/clear", `{"model_id":"`+scoringModel+`","operator_id":"op","reason":"runtime fixed"}`); code != http.StatusOK {
		t.Fatalf("clear code=%d body=%v", code, out)
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationUnverified {
		t.Fatalf("cleared state=%s", got)
	}
	if p, _ := h.registry.Resolve("cheat", "as-cheat"); p.ComputeIntegritySuspended || !p.RoutingEligible() {
		t.Fatal("clear must lift the routing suspension")
	}
	if code, _ := h.admin(http.MethodPost, "/admin/compute-integrity/cheat/clear", `{"model_id":"other","operator_id":"op","reason":"x"}`); code != http.StatusNotFound {
		t.Fatalf("clear of unknown key code=%d", code)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/compute-integrity/cheat/clear", bytes.NewBufferString(`{}`))
	rec := httptest.NewRecorder()
	h.server.handleAdminComputeIntegrity(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated action code=%d", rec.Code)
	}
}

// SPEC-036 FR-20/FR-25: no prompt, output or scorer token data reaches logs.
func TestComputeScoringLogsCarryNoPromptsOrOutputs(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 120 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
	}
	logs := h.logs.String()
	if !strings.Contains(logs, "compute_integrity_transition") {
		t.Fatal("expected transition logs")
	}
	corpus := computeintegrity.DefaultCorpus()
	forbidden := []string{"HONEST", "CHEAP", "sum_logprob", "top1_matches", "output_text"}
	for i := 0; i < corpus.Len(); i++ {
		forbidden = append(forbidden, corpus.Prompt(i).User)
	}
	for _, f := range forbidden {
		if strings.Contains(logs, f) {
			t.Fatalf("logs leak %q", f)
		}
	}
}

// FR-23: during escalation both selected scorers must answer; one silent
// scorer makes every escalation measurement inconclusive, so it can neither
// fail nor clear the key.
func TestComputeScoringPartialEscalationIsInconclusive(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	h.engine.deps.Config.ScoreDeadlineSeconds = 1
	for i := 0; i < 120 && h.state("cheat") != computeintegrity.VerificationSuspect; i++ {
		h.round(20 * time.Minute)
	}
	if h.state("cheat") != computeintegrity.VerificationSuspect {
		t.Fatal("setup: expected suspect")
	}
	h.silent.Store("scorer-b", true)
	// Fewer silent jobs than the FR-24 availability back-off limit.
	for i := 0; i < 6; i++ {
		h.round(20 * time.Minute)
	}
	h.engine.mu.Lock()
	st := h.engine.states[computeScoringKey{"cheat", scoringModel}]
	escalations := st.EscalationCount
	h.engine.mu.Unlock()
	if got := h.state("cheat"); got != computeintegrity.VerificationSuspect || escalations != 0 {
		t.Fatalf("partial answers must change no state: state=%s escalations=%d", got, escalations)
	}
}

// FR-23/FR-25: the hold and the state commit together. When the state write
// fails, the hold write rolls back with it and nothing is suspended.
func TestComputeScoringTransitionIsAtomic(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 120 && h.state("cheat") != computeintegrity.VerificationSuspect; i++ {
		h.round(20 * time.Minute)
	}
	if h.state("cheat") != computeintegrity.VerificationSuspect {
		t.Fatal("setup: expected suspect")
	}
	h.holds.breakStateWrite.Store(true)
	for i := 0; i < 40 && h.holds.attempts.Load() == 0; i++ {
		h.round(20 * time.Minute)
	}
	if h.holds.attempts.Load() == 0 {
		t.Fatal("setup: the failure transition was never attempted")
	}
	if got := h.state("cheat"); got == computeintegrity.VerificationFailed {
		t.Fatal("a transition whose state cannot persist must not apply")
	}
	if p, _ := h.registry.Resolve("cheat", "as-cheat"); p.ComputeIntegritySuspended {
		t.Fatal("no suspension without a committed transition")
	}
	var rows int
	if err := h.db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'fake_hold_log'`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		if err := h.db.QueryRow(`SELECT COUNT(*) FROM fake_hold_log`).Scan(&rows); err != nil {
			t.Fatal(err)
		}
	}
	if rows != 0 {
		t.Fatalf("the hold write must roll back with the state write, %d rows remain", rows)
	}
}

// FR-25: an operator clear whose commit fails changes nothing, in memory or
// in routing.
func TestComputeScoringOperatorClearFailureRestoresState(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 120 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
	}
	if h.state("cheat") != computeintegrity.VerificationFailed {
		t.Fatal("setup: expected failure")
	}
	if _, err := h.db.Exec(`ALTER TABLE compute_integrity_scoring_keys RENAME TO compute_integrity_scoring_keys_off`); err != nil {
		t.Fatal(err)
	}
	code, _ := h.admin(http.MethodPost, "/admin/compute-integrity/cheat/clear", `{"model_id":"`+scoringModel+`","operator_id":"op","reason":"fixed"}`)
	if code != http.StatusInternalServerError {
		t.Fatalf("clear with a failing store code=%d", code)
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationFailed {
		t.Fatalf("a failed clear must leave the key failed, got %s", got)
	}
	if p, _ := h.registry.Resolve("cheat", "as-cheat"); !p.ComputeIntegritySuspended {
		t.Fatal("a failed clear must keep the suspension")
	}
}

// FR-20: the first request of a key follows the jittered cadence.
func TestComputeScoringFirstRequestUsesJitteredCadence(t *testing.T) {
	providers := map[string]string{"a": "github:1", "b": "github:2"}
	h := newScoringHarness(t, providers, nil)
	start := h.now()
	h.engine.sweep(context.Background(), start)
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	interval := h.engine.interval(computeintegrity.VerificationUnverified)
	for key, due := range h.engine.nextDue {
		if d := due.Sub(start); d < interval/2 || d >= interval*3/2 {
			t.Fatalf("%v first due after %v, want within [0.5, 1.5) x %v", key, d, interval)
		}
	}
}

// FR-20: the hourly bound is a rolling hour and survives a restart, rebuilt
// from the recorded verification start times.
func TestComputeScoringHourlyBoundSurvivesRestart(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1"}, nil)
	for i := 0; i < 5; i++ {
		if err := h.engine.deps.Store.RecordVerificationStart(context.Background(), h.now().Add(-10*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	deps := h.engine.deps
	deps.Config.MaxPerHour = 5
	e, err := h.server.newComputeScoringEngine(context.Background(), deps)
	if err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.recentStarts) != 5 {
		t.Fatalf("restarted engine restored %d starts, want 5", len(e.recentStarts))
	}
	if e.hourlyBudgetLocked(h.now()) {
		t.Fatal("budget must be exhausted by the restored starts")
	}
	// The bound is rolling: the restored starts free their slots exactly one
	// hour after they were sent, not at a fixed reset.
	if e.hourlyBudgetLocked(h.now().Add(49 * time.Minute)) {
		t.Fatal("budget freed before the restored starts are an hour old")
	}
	if !e.hourlyBudgetLocked(h.now().Add(50*time.Minute + time.Second)) {
		t.Fatal("budget not freed once the restored starts are an hour old")
	}
}

// FR-20: a disconnect does not reset a key's verification cadence. A key
// keeps its due time while its provider is away, so reconnecting cannot
// postpone verification; it is dropped only after the retention period.
func TestComputeScoringDueTimeSurvivesReconnect(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	start := h.now()
	h.engine.sweep(context.Background(), start)
	key := computeScoringKey{"a", scoringModel}
	h.engine.mu.Lock()
	due, ok := h.engine.nextDue[key]
	h.engine.mu.Unlock()
	if !ok {
		t.Fatal("setup: key a not scheduled")
	}
	onlyB := map[string]struct{}{"b": {}}
	h.engine.prune(onlyB, start.Add(time.Minute))
	h.engine.mu.Lock()
	kept, ok := h.engine.nextDue[key]
	h.engine.mu.Unlock()
	if !ok || !kept.Equal(due) {
		t.Fatalf("due time lost or reset across a disconnect: had %v, now %v (present=%v)", due, kept, ok)
	}
	h.engine.prune(onlyB, start.Add(computeScoreRetention+time.Hour))
	h.engine.mu.Lock()
	_, ok = h.engine.nextDue[key]
	h.engine.mu.Unlock()
	if ok {
		t.Fatal("due time of a key absent past the retention period must be dropped")
	}
}

// FR-24: an operator clear wins over an exclusion write decided before it.
// A pending retry is dropped and a late write of a cleared scorer is skipped,
// so the exclusion does not come back on the next sweep or after a restart.
func TestComputeScoringClearScorerDropsPendingExclusion(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	ctx := context.Background()
	h.engine.scorers = computeintegrity.NewScorerTracker([]string{"a"})
	h.engine.mu.Lock()
	h.engine.pendingExclusions["a"] = h.now()
	h.engine.mu.Unlock()
	if err := h.engine.clearScorer(ctx, "a"); err != nil {
		t.Fatal(err)
	}
	h.engine.retryExclusions(ctx, h.now(), time.Now().Add(time.Minute))
	h.engine.persistExclusion(ctx, "a", h.now())
	excluded, err := h.engine.deps.Store.LoadScorerExclusions(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(excluded) != 0 {
		t.Fatalf("cleared scorer excluded again durably: %v", excluded)
	}
	h.engine.mu.Lock()
	n := len(h.engine.pendingExclusions)
	h.engine.mu.Unlock()
	if n != 0 || h.engine.scorers.Excluded("a") {
		t.Fatal("cleared scorer still pending or excluded in memory")
	}
}

// FR-24: only a usable measurement resets a scorer's silence. A short answer
// counts as no answer when another scorer scored the same output usably or
// the output is long; a genuinely short output penalizes nobody.
func TestComputeScoringShortAnswersCountTowardBackoff(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"v": "github:1", "a": "github:2", "b": "github:3"}, nil)
	ctx := context.Background()
	cand := func(id string) computeintegrity.ScorerCandidate {
		return computeintegrity.ScorerCandidate{ProviderID: id, AssignedID: "as-" + id, ModelID: scoringModel, ManifestSHA256: scoringModelHash, WireManifestSHA256: scoringManifest}
	}
	verified := cand("v")
	body := []byte(`{"model":"model-ci"}`)
	h.short.Store("a", true)
	h.short.Store("b", true)
	for i := 0; i < 10; i++ {
		if _, _, complete := h.engine.scoreAll(ctx, []computeintegrity.ScorerCandidate{cand("a"), cand("b")}, verified, body, "tiny", ""); complete {
			t.Fatal("short measurements must not complete")
		}
	}
	if !h.engine.scorers.Available("a", h.now()) || !h.engine.scorers.Available("b", h.now()) {
		t.Fatal("a short output must not rest its scorers")
	}
	h.short.Delete("b")
	for i := 0; i < 8; i++ {
		h.engine.scoreAll(ctx, []computeintegrity.ScorerCandidate{cand("a"), cand("b")}, verified, body, "HONEST output", "")
	}
	if h.engine.scorers.Available("a", h.now()) {
		t.Fatal("a scorer answering short where another scored usably must rest after the silence limit")
	}
	if !h.engine.scorers.Available("b", h.now()) {
		t.Fatal("the usable scorer must stay available")
	}
	h.short.Store("b", true)
	long := strings.Repeat("word ", computeScoreShortOutputBytes/5+1)
	for i := 0; i < 8; i++ {
		h.engine.scoreAll(ctx, []computeintegrity.ScorerCandidate{cand("b")}, verified, body, long, "")
	}
	if h.engine.scorers.Available("b", h.now()) {
		t.Fatal("a scorer answering short on a long output must rest after the silence limit")
	}
}

// FR-24: known-sequence checks take part in silence accounting like any
// other job: a short answer counts toward the back-off and fails the check.
func TestComputeScoringKnownChecksCountTowardBackoff(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1"}, nil)
	ctx := context.Background()
	tkey := computeintegrity.ToleranceKey{ModelID: scoringModel, ManifestSHA256: scoringModelHash, Class: computeintegrity.SamplingGreedy}
	good := computeintegrity.Measurement{ScoredTokens: 100, Top1Matches: 98, SumLogprob: -18}
	h.engine.known.Offer(tkey, computeintegrity.KnownSequence{
		Body: []byte(`{"model":"model-ci"}`), OutputText: "HONEST output",
		SourceProvider: "x", SourceOperator: "github:9",
		Scorers: []string{"y", "z"}, ScorerOperators: []string{"github:7", "github:8"},
	}, good, good, h.now())
	h.short.Store("a", true)
	for i := 0; i < 8; i++ {
		h.engine.knownSequenceCheck(ctx, computeintegrity.ToleranceKey{ModelID: scoringModel, ManifestSHA256: scoringModelHash})
	}
	if h.engine.scorers.Available("a", h.now()) {
		t.Fatal("short known-check answers must count toward the silence back-off")
	}
}

// A failed operator-key lookup is cached briefly and pushes the key to its
// next cadence slot, so an identity-store outage is not retried every sweep.
func TestComputeScoringOperatorLookupFailureBacksOff(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	var lookups atomic.Int64
	h.engine.deps.OperatorKey = func(context.Context, string) (string, error) {
		lookups.Add(1)
		return "", errors.New("identity store down")
	}
	h.round(2 * time.Hour) // schedules first requests
	h.round(2 * time.Hour) // due: lookups fail
	after := lookups.Load()
	if after == 0 {
		t.Fatal("setup: no lookup attempted")
	}
	h.round(10 * time.Second)
	if lookups.Load() != after {
		t.Fatalf("lookups repeated within the negative cache: %d -> %d", after, lookups.Load())
	}
	if h.dispatched.Load() != 0 {
		t.Fatal("no verification request without an operator identity")
	}
}

// FR-21: a provider runs one scoring job at a time, so a scorer busy with
// one job is not chosen for another. A key whose only scorers are busy stays
// due and is retried once they are free, instead of measuring with fewer.
func TestComputeScoringBusyScorerIsNotDoubleBooked(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	h.round(2 * time.Hour) // schedules first requests
	h.engine.mu.Lock()
	h.engine.scorerBusy["a"] = true
	h.engine.scorerBusy["b"] = true
	h.engine.mu.Unlock()
	h.round(2 * time.Hour) // both due, every scorer busy
	if n := h.dispatched.Load(); n != 0 {
		t.Fatalf("dispatched %d verification requests with every scorer busy", n)
	}
	h.engine.mu.Lock()
	for key, due := range h.engine.nextDue {
		if due.After(h.now()) {
			t.Errorf("%v rescheduled to %v; it must stay due while its scorer is busy", key, due)
		}
	}
	delete(h.engine.scorerBusy, "a")
	delete(h.engine.scorerBusy, "b")
	h.engine.mu.Unlock()
	h.round(time.Second)
	if h.dispatched.Load() == 0 {
		t.Fatal("a due key must be verified once its scorer is free")
	}
	h.engine.mu.Lock()
	busy := len(h.engine.scorerBusy)
	h.engine.mu.Unlock()
	if busy != 0 {
		t.Fatalf("scorer reservations leaked: %d", busy)
	}
}

// FR-21: scorer cohorts are keyed by the coordinator-verified catalog model
// hash, not the provider-reported manifest, so reporting a different
// manifest does not take a provider out of its cohort. The job to a scorer
// carries that scorer's own manifest.
func TestComputeScoringCohortUsesVerifiedModelHash(t *testing.T) {
	liar := scoringCandidate(pool.Provider{ProviderID: "liar", AssignedID: "as-liar", ModelID: scoringModel, ModelHash: scoringModelHash, WeightsManifestSHA256: strings.Repeat("a", 64), ComputeScoreV1: true})
	liar.OperatorKey = "github:1"
	honest := scoringCandidate(pool.Provider{ProviderID: "honest", AssignedID: "as-honest", ModelID: scoringModel, ModelHash: scoringModelHash, WeightsManifestSHA256: scoringManifest, ComputeScoreV1: true})
	honest.OperatorKey = "github:2"
	got := computeintegrity.SelectScorers(rand.New(rand.NewSource(1)), liar, []computeintegrity.ScorerCandidate{honest}, 1, nil)
	if len(got) != 1 || got[0].ProviderID != "honest" || got[0].WireManifestSHA256 != scoringManifest {
		t.Fatalf("a different reported manifest must not leave the cohort: %+v", got)
	}
}

// FR-20: if the verification history cannot be read at start, the hourly
// bound fails closed for one hour.
func TestComputeScoringHourlyBoundFailsClosedWithoutHistory(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1"}, nil)
	if _, err := h.db.Exec(`INSERT INTO compute_integrity_verification_starts VALUES ('not-a-time')`); err != nil {
		t.Fatal(err)
	}
	deps := h.engine.deps
	deps.Config.MaxPerHour = 5
	e, err := h.server.newComputeScoringEngine(context.Background(), deps)
	if err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.hourlyBudgetLocked(h.now().Add(59 * time.Minute)) {
		t.Fatal("unreadable history must leave no hourly budget for one hour")
	}
	if !e.hourlyBudgetLocked(h.now().Add(time.Hour + time.Second)) {
		t.Fatal("the budget must free one hour after start")
	}
}

// FR-23: a key state restored at start survives until its provider has been
// away for the retention period, so a provider that reconnects after a
// coordinator restart resumes its state and affected window.
func TestComputeScoringRestoredStateSurvivesRestartBeforeReconnect(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	for i := 0; i < 20 && h.state("a") != computeintegrity.VerificationPassing; i++ {
		h.round(2 * time.Hour)
	}
	if h.state("a") != computeintegrity.VerificationPassing {
		t.Fatal("setup: expected passing")
	}
	e, err := h.server.newComputeScoringEngine(context.Background(), h.engine.deps)
	if err != nil {
		t.Fatal(err)
	}
	e.prune(map[string]struct{}{}, h.now().Add(time.Minute))
	e.mu.Lock()
	st := e.states[computeScoringKey{"a", scoringModel}]
	e.mu.Unlock()
	if st == nil || st.State != computeintegrity.VerificationPassing {
		t.Fatalf("restored state pruned before its provider reconnected: %+v", st)
	}
}

// FR-20: a due request is spread over one sweep interval, so its arrival
// carries no sweep-tick phase.
func TestComputeScoringDispatchDelaySpansSweep(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1"}, nil)
	e, err := h.server.newComputeScoringEngine(context.Background(), h.engine.deps)
	if err != nil {
		t.Fatal(err)
	}
	sweep := e.tickInterval()
	var lo, hi time.Duration = sweep, 0
	for i := 0; i < 2000; i++ {
		d := e.dispatchDelay()
		if d < 0 || d >= sweep {
			t.Fatalf("delay %v outside [0, %v)", d, sweep)
		}
		lo, hi = min(lo, d), max(hi, d)
	}
	if lo > sweep/10 || hi < sweep*9/10 {
		t.Fatalf("delays [%v, %v] do not span the sweep interval %v", lo, hi, sweep)
	}
}

// FR-20: the sweep deadline bounds identity lookups inside a provider's
// scorer pool, not only between providers. Out of time, the key stays due
// and no request is reserved.
func TestComputeScoringSweepDeadlineBoundsLookups(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2", "c": "github:3"}, nil)
	h.round(2 * time.Hour) // schedules first requests
	h.advance(2 * time.Hour)
	var p pool.Provider
	var cands []computeintegrity.ScorerCandidate
	for _, q := range h.registry.Snapshot() {
		if q.ProviderID == "a" {
			p = q
		}
		cands = append(cands, scoringCandidate(q))
	}
	h.engine.considerProvider(context.Background(), p, cands, h.now(), time.Now().Add(-time.Second))
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	if h.engine.inFlightCount != 0 || len(h.engine.recentStarts) != 0 {
		t.Fatalf("a request was reserved past the sweep deadline: in_flight=%d starts=%d", h.engine.inFlightCount, len(h.engine.recentStarts))
	}
	if due := h.engine.nextDue[computeScoringKey{"a", scoringModel}]; due.After(h.now()) {
		t.Fatal("a key cut off by the deadline must stay due")
	}
}

// FR-20: a request's start is recorded durably at dispatch, stamped at the
// latest moment the dispatch can begin, and persisted for a restart; a
// reservation holds budget until then.
func TestComputeScoringStartCountedAtDispatch(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	h.round(2 * time.Hour)
	h.round(2 * time.Hour)
	if h.dispatched.Load() == 0 {
		t.Fatal("setup: expected a verification request")
	}
	h.engine.mu.Lock()
	starts := append([]time.Time(nil), h.engine.recentStarts...)
	pending := h.engine.pendingStarts
	h.engine.mu.Unlock()
	if pending != 0 {
		t.Fatalf("pending reservations leaked: %d", pending)
	}
	for _, s := range starts {
		if s.Before(h.now().Add(computeScoreLookupTimeout)) {
			t.Fatalf("start %v counted before the latest dispatch %v", s, h.now().Add(computeScoreLookupTimeout))
		}
	}
	got, err := h.engine.deps.Store.RecentVerificationRequests(context.Background(), h.now().Add(-time.Hour), 100)
	if err != nil || len(got) != len(starts) || int64(len(got)) != h.dispatched.Load() {
		t.Fatalf("persisted %d starts err=%v, want %d (dispatched %d)", len(got), err, len(starts), h.dispatched.Load())
	}
}

// FR-20: if a start cannot be made durable, the request is not sent and its
// reservation is released.
func TestComputeScoringUnpersistedStartIsNotDispatched(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	h.round(2 * time.Hour)
	if _, err := h.db.Exec(`DROP TABLE compute_integrity_verification_starts`); err != nil {
		t.Fatal(err)
	}
	h.round(2 * time.Hour)
	if n := h.dispatched.Load(); n != 0 {
		t.Fatalf("dispatched %d requests whose start was not durable", n)
	}
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	if h.engine.pendingStarts != 0 || len(h.engine.recentStarts) != 0 {
		t.Fatalf("pending=%d starts=%d after failed persistence", h.engine.pendingStarts, len(h.engine.recentStarts))
	}
}

// FR-20: a lookup that returns after the sweep deadline reserves nothing,
// and its cut-off result is not cached as a failure.
func TestComputeScoringLookupPastDeadlineReservesNothing(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	h.round(2 * time.Hour)
	h.advance(2 * time.Hour)
	inner := h.engine.deps.OperatorKey
	h.engine.deps.OperatorKey = func(ctx context.Context, id string) (string, error) {
		<-ctx.Done()
		return "", ctx.Err()
	}
	var p pool.Provider
	var cands []computeintegrity.ScorerCandidate
	for _, q := range h.registry.Snapshot() {
		if q.ProviderID == "a" {
			p = q
		}
		cands = append(cands, scoringCandidate(q))
	}
	h.engine.considerProvider(context.Background(), p, cands, h.now(), time.Now().Add(50*time.Millisecond))
	h.engine.mu.Lock()
	if h.engine.inFlightCount != 0 || h.engine.pendingStarts != 0 {
		h.engine.mu.Unlock()
		t.Fatal("a lookup past the deadline must reserve nothing")
	}
	_, cached := h.engine.operatorKeys["a"]
	due := h.engine.nextDue[computeScoringKey{"a", scoringModel}]
	h.engine.mu.Unlock()
	if cached {
		t.Fatal("a lookup cut off by the deadline must not be cached as a failure")
	}
	if due.After(h.now()) {
		t.Fatal("the key must stay due")
	}
	h.engine.deps.OperatorKey = inner
}
