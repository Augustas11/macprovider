package payout

import (
	"context"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// ChronicOutageTracker watches a sliding window of per-RPC-label
// outcomes and emits a payout_rpc_chronic_outage PAGE when the
// per-label error rate crosses the configured threshold AND the
// per-label sample count is large enough to make the rate
// statistically actionable. Closes #165 A2 (advisory from
// SPEC-016 IMPL FULL r1 [arch:4.5]).
//
// Why per-label, not aggregate: the disagreement detector (§4.4
// receipts-agree, §6.2 chain-balance) already pages on
// disagreement, which only fires when BOTH RPCs return data AND
// the data conflicts. A chronic single-RPC failure leaves the
// healthy RPC's reads usable (the runner degrades; e.g.
// ReceiptsAgree returns false → row stays pending → next cycle
// retries) but produces no operator-facing event. This tracker
// closes that gap.
//
// Defaults (overridable by tests):
//
//   - window     = 10 minutes
//   - threshold  = 0.5 (50% error rate)
//   - minSamples = 10  (avoid false PAGE on a cold runner)
//   - cooldown   = 10 minutes (PAGE at most once per cooldown per
//     label so a chronic outage doesn't flood the journal)
type ChronicOutageTracker struct {
	window     time.Duration
	threshold  float64
	minSamples int
	cooldown   time.Duration
	log        zerolog.Logger
	nowFn      func() time.Time

	mu     sync.Mutex
	states map[string]*chronicLabelState
}

type chronicLabelState struct {
	samples     []chronicSample
	lastPagedAt time.Time
}

type chronicSample struct {
	ts    time.Time
	isErr bool
}

// NewChronicOutageTracker constructs a tracker with SPEC §7.1
// defaults. Pass nowFn=nil to use time.Now.
func NewChronicOutageTracker(log zerolog.Logger, nowFn func() time.Time) *ChronicOutageTracker {
	if nowFn == nil {
		nowFn = time.Now
	}
	return &ChronicOutageTracker{
		window:     10 * time.Minute,
		threshold:  0.5,
		minSamples: 10,
		cooldown:   10 * time.Minute,
		log:        log,
		nowFn:      nowFn,
		states:     make(map[string]*chronicLabelState),
	}
}

// WithWindow / WithThreshold / WithMinSamples / WithCooldown are
// test-only configuration hooks. They return the receiver for
// chaining and MUST be called before any Record / Evaluate to
// avoid racing with the runner.
func (t *ChronicOutageTracker) WithWindow(w time.Duration) *ChronicOutageTracker {
	t.window = w
	return t
}

func (t *ChronicOutageTracker) WithThreshold(th float64) *ChronicOutageTracker {
	t.threshold = th
	return t
}

func (t *ChronicOutageTracker) WithMinSamples(n int) *ChronicOutageTracker {
	t.minSamples = n
	return t
}

func (t *ChronicOutageTracker) WithCooldown(c time.Duration) *ChronicOutageTracker {
	t.cooldown = c
	return t
}

// Record adds one outcome sample for the named RPC label. Calls
// from any goroutine are safe; the per-label state mutex is held
// only while appending.
func (t *ChronicOutageTracker) Record(label string, isErr bool) {
	if t == nil || label == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	st, ok := t.states[label]
	if !ok {
		st = &chronicLabelState{}
		t.states[label] = st
	}
	st.samples = append(st.samples, chronicSample{ts: t.nowFn(), isErr: isErr})
}

// Evaluate prunes stale samples, checks every label's window, and
// emits payout_rpc_chronic_outage for any label that crossed the
// threshold and is outside its cooldown. Returns the labels that
// emitted this call; useful for tests + per-cycle telemetry counts.
// Safe to call from the runner cycle loop.
func (t *ChronicOutageTracker) Evaluate(_ context.Context, now time.Time) []string {
	if t == nil {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	cutoff := now.Add(-t.window)
	var paged []string
	for label, st := range t.states {
		// Prune. Samples are append-only and ts is monotonic per
		// label, so a single linear scan suffices.
		idx := 0
		for idx < len(st.samples) && st.samples[idx].ts.Before(cutoff) {
			idx++
		}
		if idx > 0 {
			st.samples = append(st.samples[:0], st.samples[idx:]...)
		}
		if len(st.samples) < t.minSamples {
			continue
		}
		errs := 0
		for _, s := range st.samples {
			if s.isErr {
				errs++
			}
		}
		rate := float64(errs) / float64(len(st.samples))
		if rate < t.threshold {
			continue
		}
		if !st.lastPagedAt.IsZero() && now.Sub(st.lastPagedAt) < t.cooldown {
			continue
		}
		st.lastPagedAt = now
		t.log.Error().
			Str("event", "payout_rpc_chronic_outage").
			Str("rpc_label", label).
			Int("window_seconds", int(t.window.Seconds())).
			Int("sample_count", len(st.samples)).
			Int("error_count", errs).
			Float64("error_rate", rate).
			Float64("threshold", t.threshold).
			Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
			Str("severity", "PAGE").
			Send()
		paged = append(paged, label)
	}
	return paged
}

// ---- trackingRPC wrapper -------------------------------------------------

// NewTrackingRPCClient wraps an RPCClient so every call records
// success/failure into the tracker. Returns inner unchanged when
// tracker is nil — tests that don't care about chronic-outage
// observability don't have to wire one.
//
// What counts as an error: a non-nil error return. The
// (nil receipt, nil error) "not found" success path for
// TransactionReceipt/TransactionByHash is NOT counted as an error —
// it's a normal RPC response, not an outage signal. This matches
// the §4.7 producer's own "RPC error is NOT a stale signal"
// classification (orphans.go line ~450).
func NewTrackingRPCClient(inner RPCClient, tracker *ChronicOutageTracker) RPCClient {
	if tracker == nil {
		return inner
	}
	return &trackingRPC{inner: inner, tracker: tracker}
}

type trackingRPC struct {
	inner   RPCClient
	tracker *ChronicOutageTracker
}

func (t *trackingRPC) record(err error) {
	t.tracker.Record(t.inner.Label(), err != nil)
}

func (t *trackingRPC) Label() string { return t.inner.Label() }

func (t *trackingRPC) ChainID(ctx context.Context) (uint64, error) {
	v, err := t.inner.ChainID(ctx)
	t.record(err)
	return v, err
}

func (t *trackingRPC) TransactionCount(ctx context.Context, address string) (uint64, error) {
	v, err := t.inner.TransactionCount(ctx, address)
	t.record(err)
	return v, err
}

func (t *trackingRPC) SendRawTransaction(ctx context.Context, rawSignedTx []byte) (string, error) {
	v, err := t.inner.SendRawTransaction(ctx, rawSignedTx)
	t.record(err)
	return v, err
}

func (t *trackingRPC) TransactionReceipt(ctx context.Context, txHash string) (*Receipt, error) {
	v, err := t.inner.TransactionReceipt(ctx, txHash)
	t.record(err)
	return v, err
}

func (t *trackingRPC) TransactionByHash(ctx context.Context, txHash string) (*Transaction, error) {
	v, err := t.inner.TransactionByHash(ctx, txHash)
	t.record(err)
	return v, err
}

func (t *trackingRPC) BlockNumber(ctx context.Context) (uint64, error) {
	v, err := t.inner.BlockNumber(ctx)
	t.record(err)
	return v, err
}

func (t *trackingRPC) CallContract(ctx context.Context, to string, data []byte) ([]byte, error) {
	v, err := t.inner.CallContract(ctx, to, data)
	t.record(err)
	return v, err
}

func (t *trackingRPC) NativeBalance(ctx context.Context, address string) (uint64, error) {
	v, err := t.inner.NativeBalance(ctx, address)
	t.record(err)
	return v, err
}
