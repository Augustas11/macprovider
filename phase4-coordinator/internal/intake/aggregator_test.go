package intake

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"strings"
	"testing"
	"time"
)

type fixedRandom struct{ seed int64 }

func (f *fixedRandom) Read(p []byte) (int, error) {
	r := rand.New(rand.NewSource(f.seed))
	f.seed++
	for i := range p {
		p[i] = byte(r.Intn(256))
	}
	return len(p), nil
}

func lowerNormalize(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newTestAggregator(t *testing.T, params Params, opts ...Option) (*Aggregator, *clock) {
	t.Helper()
	c := &clock{t: time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)}
	opts = append([]Option{WithClock(c.now), WithRandom(&fixedRandom{seed: 1})}, opts...)
	a, err := New(params, lowerNormalize, opts...)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return a, c
}

// openWindow reads the OPEN window through the local diagnostic dump; the
// served Snapshot carries complete windows only.
func openWindow(t *testing.T, a *Aggregator) Window {
	t.Helper()
	dump, err := a.DiagnosticDump()
	if err != nil {
		t.Fatal(err)
	}
	var um UnmatchedModels
	if err := json.Unmarshal(dump, &um); err != nil {
		t.Fatal(err)
	}
	if len(um.Windows) != 1 || um.Windows[0].CloseReason != nil {
		t.Fatalf("no open window in dump: %+v", um)
	}
	return um.Windows[0]
}

// lowFloor makes the floor rule inert so the S-order tests can inspect
// per-key bounds; the floor rule has its own test.
func lowFloor() Params {
	p := DefaultParams()
	p.BuyerRequestFloor = 10
	p.PrincipalCapPct = 100 // cap 10 per principal
	return p
}

func bucketFor(w Window, key string) (Bucket, bool) {
	for _, b := range w.Buckets {
		if b.ModelKey == key {
			return b, true
		}
	}
	return Bucket{}, false
}

func TestParamsValidate(t *testing.T) {
	if err := DefaultParams().Validate(); err != nil {
		t.Fatalf("defaults invalid: %v", err)
	}
	bad := DefaultParams()
	bad.BuyerRequestFloor = 5
	bad.PrincipalCapPct = 10
	if err := bad.Validate(); err == nil {
		t.Fatalf("expected floor×pct/100 < 1 to be rejected")
	}
	if got := DefaultParams().PrincipalCapRequests(); got != 25 {
		t.Fatalf("PrincipalCapRequests = %d, want 25", got)
	}
}

func TestS1IneligibleContributesToNothing(t *testing.T) {
	a, _ := newTestAggregator(t, DefaultParams(), WithExcludedAccounts([]string{"keepwarm"}))
	a.Observe("qwen3-14b", "")
	a.Observe("qwen3-14b", "keepwarm")
	w := openWindow(t, a)
	if w.EligibleRequestTotal != 0 || len(w.Buckets) != 0 || w.OtherSuppressed.RequestCount != 0 {
		t.Fatalf("ineligible requests contributed: %+v", w)
	}
}

func TestS3GrammarGoesToOtherSuppressedOnly(t *testing.T) {
	a, _ := newTestAggregator(t, lowFloor())
	a.Observe("Qwen 3 14B!", "acct-1")            // space and '!' out of grammar
	a.Observe(strings.Repeat("a", 129), "acct-1") // over 128 bytes
	a.Observe("ünicode", "acct-1")                // non-ASCII
	a.Observe(strings.Repeat("a", 128), "acct-1") // exactly 128: eligible
	w := openWindow(t, a)
	if w.EligibleRequestTotal != 4 {
		t.Fatalf("eligible_request_total = %d, want 4", w.EligibleRequestTotal)
	}
	if w.OtherSuppressed.RequestCount != 3 || w.OtherSuppressed.DistinctKeyCount != 3 {
		t.Fatalf("other_suppressed = %+v, want 3/3", w.OtherSuppressed)
	}
	// The eligible key was requested by one principal only: retained but
	// omitted from the wire (SPEC-017 §5.2b.4).
	if len(w.Buckets) != 0 || w.SuppressedBucketCount != 1 {
		t.Fatalf("buckets = %+v suppressed=%d, want 0 emitted / 1 suppressed", w.Buckets, w.SuppressedBucketCount)
	}
	for i := 0; i < 3; i++ {
		for j := 0; j < 4; j++ {
			a.Observe(strings.Repeat("a", 128), fmt.Sprintf("acct-%d", i+2))
		}
	}
	w = openWindow(t, a)
	if len(w.Buckets) != 1 || w.Buckets[0].ModelKey != strings.Repeat("a", 128) || w.SuppressedBucketCount != 0 || w.Buckets[0].LowerBound != 13 {
		t.Fatalf("three principals clearing the floor should emit the bucket: %+v suppressed=%d", w.Buckets, w.SuppressedBucketCount)
	}
}

func TestS4PrincipalCapAndSuppression(t *testing.T) {
	p := DefaultParams() // cap 25, floor 250
	a, _ := newTestAggregator(t, p)
	for i := 0; i < 40; i++ {
		a.Observe("qwen3-14b", "single-buyer")
	}
	w := openWindow(t, a)
	// One principal, 40 requests: capped at 25 internally, and ABSENT from
	// the wire (k-anonymity counts distinct principals; the floor is unmet).
	if _, ok := bucketFor(w, "qwen3-14b"); ok || w.SuppressedBucketCount != 1 {
		t.Fatalf("single-principal bucket must be omitted: %+v suppressed=%d", w.Buckets, w.SuppressedBucketCount)
	}
	if w.OtherSuppressed.RequestCount != 15 {
		t.Fatalf("over-cap traffic not discarded into other_suppressed: %+v", w.OtherSuppressed)
	}
	dump, _ := a.DiagnosticDump()
	if bytes.Contains(dump, []byte("qwen3-14b")) {
		t.Fatalf("a key requested by one principal must not appear in emitted bytes: %s", dump)
	}
	// Three principals but a lower bound of 27: still below the floor,
	// still absent.
	a.Observe("qwen3-14b", "buyer-b")
	a.Observe("qwen3-14b", "buyer-c")
	w = openWindow(t, a)
	if _, ok := bucketFor(w, "qwen3-14b"); ok || w.SuppressedBucketCount != 1 {
		t.Fatalf("sub-floor bucket must be omitted even with three principals: %+v", w.Buckets)
	}
	// Ten independent principals at the cap clear 250 and the key appears.
	a2, _ := newTestAggregator(t, p)
	for i := 0; i < 10; i++ {
		for j := 0; j < 25; j++ {
			a2.Observe("qwen3-14b", fmt.Sprintf("buyer-%d", i))
		}
	}
	b, ok := bucketFor(openWindow(t, a2), "qwen3-14b")
	if !ok || !b.ClearsFloor(250) || b.LowerBound != 250 || b.Count != 250 || b.Error != 0 {
		t.Fatalf("ten independent principals at the cap should clear 250: %+v", b)
	}
	// Nine principals at the cap (225) plus one more principal's 24: 249 < 250, absent.
	a3, _ := newTestAggregator(t, p)
	for i := 0; i < 9; i++ {
		for j := 0; j < 25; j++ {
			a3.Observe("qwen3-14b", fmt.Sprintf("buyer-%d", i))
		}
	}
	for j := 0; j < 24; j++ {
		a3.Observe("qwen3-14b", "buyer-9")
	}
	if _, ok := bucketFor(openWindow(t, a3), "qwen3-14b"); ok {
		t.Fatalf("249 must not clear 250")
	}
}

func TestS4PrincipalOverflowGoesToOtherSuppressed(t *testing.T) {
	p := lowFloor()
	p.PrincipalsPerBucket = 3
	a, _ := newTestAggregator(t, p)
	for i := 0; i < 4; i++ {
		a.Observe("k", "p1")
		a.Observe("k", "p2")
		a.Observe("k", "p3")
	}
	a.Observe("k", "p4") // overflow principal
	w := openWindow(t, a)
	b, ok := bucketFor(w, "k")
	if !ok || b.LowerBound != 12 {
		t.Fatalf("bucket = %+v, want lower_bound 12 (p4 excluded)", b)
	}
	if w.OtherSuppressed.RequestCount != 1 {
		t.Fatalf("overflow principal not routed to other_suppressed: %+v", w.OtherSuppressed)
	}
}

func TestS5EvictionIsDeterministicAndTransfersOnce(t *testing.T) {
	p := lowFloor()
	p.KeyBuckets = 2
	run := func() (UnmatchedModels, Window) {
		a, _ := newTestAggregator(t, p)
		for i := 0; i < 5; i++ {
			a.Observe("alpha", fmt.Sprintf("a%d", i))
			a.Observe("alpha", fmt.Sprintf("a%d", i))
		}
		for i := 0; i < 3; i++ {
			a.Observe("beta", fmt.Sprintf("b%d", i))
		}
		// Summary full: gamma evicts beta (smallest count 3) -> count 4, error 3.
		a.Observe("gamma", "g0")
		// delta evicts gamma (count 4 < alpha 10) -> count 5, error 4; only
		// gamma's non-inherited contribution (4-3 = 1) transfers.
		a.Observe("delta", "d0")
		dump, _ := a.DiagnosticDump()
		var um UnmatchedModels
		_ = json.Unmarshal(dump, &um)
		return um, openWindow(t, a)
	}
	s1, w := run()
	s2, _ := run()
	j1, _ := json.Marshal(s1)
	j2, _ := json.Marshal(s2)
	if !bytes.Equal(j1, j2) {
		t.Fatalf("two runs over one request order differ:\n%s\n%s", j1, j2)
	}
	if _, ok := bucketFor(w, "delta"); ok {
		t.Fatalf("delta (one principal, lower bound 1) must not be emitted")
	}
	if len(w.Buckets) != 1 || w.Buckets[0].ModelKey != "alpha" || w.Buckets[0].LowerBound != 10 || w.SuppressedBucketCount != 1 {
		t.Fatalf("emitted = %+v suppressed=%d, want alpha only", w.Buckets, w.SuppressedBucketCount)
	}
	if w.OtherSuppressed.RequestCount != 3+1 {
		t.Fatalf("eviction transfer = %d, want beta 3 + gamma non-inherited 1", w.OtherSuppressed.RequestCount)
	}
	if w.OtherSuppressed.DistinctKeyCount != 2 {
		t.Fatalf("distinct_key_count = %d, want 2 evictions", w.OtherSuppressed.DistinctKeyCount)
	}
	if len(w.Buckets)+w.SuppressedBucketCount != 2 {
		t.Fatalf("summary exceeded capacity: %+v + %d", w.Buckets, w.SuppressedBucketCount)
	}
}

func TestVictimTieRules(t *testing.T) {
	entries := []*entry{
		{key: "b", count: 2, err: 1},
		{key: "a", count: 2, err: 1},
		{key: "c", count: 2, err: 0},
		{key: "d", count: 3, err: 3},
	}
	if v := selectVictim(entries); v.key != "a" {
		t.Fatalf("victim = %q, want a (smallest count, largest error, smallest key)", v.key)
	}
}

func TestMemoryBoundedUnderDistinctKeyFanout(t *testing.T) {
	p := DefaultParams()
	a, _ := newTestAggregator(t, p)
	for i := 0; i < 200_000; i++ {
		a.Observe(fmt.Sprintf("model-%d", i), fmt.Sprintf("acct-%d", i%7))
	}
	a.mu.Lock()
	entries := len(a.open.entries)
	principals := 0
	for _, e := range a.open.entries {
		principals += len(e.principals)
	}
	indexed := len(a.open.index)
	a.mu.Unlock()
	if entries > p.KeyBuckets || indexed > p.KeyBuckets {
		t.Fatalf("summary grew past capacity: %d entries / %d indexed", entries, indexed)
	}
	if principals > p.KeyBuckets*p.PrincipalsPerBucket {
		t.Fatalf("principal counters %d exceed %d", principals, p.KeyBuckets*p.PrincipalsPerBucket)
	}
	w := openWindow(t, a)
	if !w.OtherSuppressed.DistinctKeyCountSaturated || w.OtherSuppressed.DistinctKeyCount != uint64(p.DistinctKeyCap) {
		t.Fatalf("distinct_key_count should saturate at the cap with its own flag: %+v", w.OtherSuppressed)
	}
	if w.OtherSuppressed.RequestCountSaturated {
		t.Fatalf("request_count must not be flagged saturated: %+v", w.OtherSuppressed)
	}
}

func TestMemoryBoundedUnderDistinctPrincipalFanout(t *testing.T) {
	p := lowFloor()
	a, _ := newTestAggregator(t, p)
	for i := 0; i < 200_000; i++ {
		a.Observe("one-key", fmt.Sprintf("acct-%d", i))
	}
	a.mu.Lock()
	tracked := len(a.open.entries[0].principals)
	a.mu.Unlock()
	if tracked != p.PrincipalsPerBucket {
		t.Fatalf("tracked principals = %d, want %d", tracked, p.PrincipalsPerBucket)
	}
	w := openWindow(t, a)
	b, _ := bucketFor(w, "one-key")
	if b.LowerBound != uint64(p.PrincipalsPerBucket) {
		t.Fatalf("overflow principals must not count: lower_bound %d", b.LowerBound)
	}
	if w.OtherSuppressed.RequestCount != 200_000-uint64(p.PrincipalsPerBucket) {
		t.Fatalf("overflow traffic not in other_suppressed: %+v", w.OtherSuppressed)
	}
}

func TestRawPrincipalIsTransientAndDumpIsOnlyTheOpenWindow(t *testing.T) {
	a, _ := newTestAggregator(t, DefaultParams())
	const raw = "buyer-account-SECRET-7f3a"
	a.Observe("qwen3-14b", raw)
	dump, err := a.DiagnosticDump()
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(dump, []byte(raw)) || bytes.Contains(dump, []byte("SECRET")) {
		t.Fatalf("dump leaks the raw principal: %s", dump)
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(dump, &obj); err != nil {
		t.Fatal(err)
	}
	for k := range obj {
		if k != "contract" && k != "windows" {
			t.Fatalf("dump carries unexpected key %q", k)
		}
	}
	var um UnmatchedModels
	if err := json.Unmarshal(dump, &um); err != nil {
		t.Fatal(err)
	}
	if len(um.Windows) != 1 || um.Windows[0].CloseReason != nil || um.Windows[0].WindowEnd != nil {
		t.Fatalf("dump must hold exactly the open window: %+v", um.Windows)
	}
	if len(a.Snapshot().Windows) != 0 {
		t.Fatalf("the served snapshot must never carry the open window")
	}
	// No aggregator state holds the raw id either.
	a.mu.Lock()
	var state bytes.Buffer
	fmt.Fprintf(&state, "%v %v", a.open.index, a.open.entries)
	for _, e := range a.open.entries {
		fmt.Fprintf(&state, "%v", e.principals)
	}
	a.mu.Unlock()
	if bytes.Contains(state.Bytes(), []byte(raw)) {
		t.Fatalf("aggregator state holds the raw principal")
	}
}

func TestWindowsCloseOnStopParamsAndEpoch(t *testing.T) {
	a, c := newTestAggregator(t, DefaultParams())
	a.Observe("k1", "p")
	first := openWindow(t, a)
	if first.Parameters.KAnonymityMin != KAnonymityMin || first.Parameters.KeyBuckets != 64 {
		t.Fatalf("window parameters = %+v", first.Parameters)
	}
	// Parameter change closes with parameters_changed: incomplete, never served.
	p := DefaultParams()
	p.KeyBuckets = 32
	if err := a.SetParams(p); err != nil {
		t.Fatal(err)
	}
	if got := a.Snapshot(); len(got.Windows) != 0 {
		t.Fatalf("an incomplete (parameters_changed) window must not be served: %+v", got.Windows)
	}
	second := openWindow(t, a)
	if second.WindowID == first.WindowID || second.Parameters.KeyBuckets != 32 {
		t.Fatalf("new window not opened with new parameters: %+v", second)
	}
	a.mu.Lock()
	retained := len(a.closed)
	a.mu.Unlock()
	if retained != 0 {
		t.Fatalf("an incomplete window must be destroyed, not retained: %d", retained)
	}
	if lc := a.LastClose(); lc.Reason != CloseReasonParametersChanged || lc.WindowID != first.WindowID {
		t.Fatalf("last close record = %+v", lc)
	}
	if first.Parameters.PrincipalCapPct != 10 || first.Parameters.PrincipalCapRequests != 25 {
		t.Fatalf("parameters must carry the raw cap pct and the derived cap: %+v", first.Parameters)
	}
	// Epoch elapse closes with epoch_elapsed: complete, served with the
	// parameters it opened with.
	c.t = c.t.Add(WindowMaxDays*24*time.Hour + time.Second)
	a.Observe("k2", "p")
	snap := a.Snapshot()
	if len(snap.Windows) != 1 || snap.Windows[0].WindowID != second.WindowID || !snap.Windows[0].Complete() || snap.Windows[0].Parameters.KeyBuckets != 32 {
		t.Fatalf("epoch_elapsed window not served as complete: %+v", snap.Windows)
	}
	if openWindow(t, a).EligibleRequestTotal != 1 {
		t.Fatalf("new window must start empty")
	}
	// Stop closes with aggregator_stopped (incomplete); later observations are no-ops.
	a.mu.Lock()
	live := a.open
	a.mu.Unlock()
	a.Stop()
	a.Observe("k3", "p")
	if got := a.Snapshot(); len(got.Windows) != 1 {
		t.Fatalf("stopped window must not be served: %+v", got.Windows)
	}
	if live.key != [windowKeyBytes]byte{} || live.entries != nil || live.index != nil {
		t.Fatalf("window key and principal tables not destroyed at close")
	}
}

func TestEmissionBoundedToEightWindowsAndNinetyDays(t *testing.T) {
	a, c := newTestAggregator(t, DefaultParams())
	for i := 0; i < 12; i++ {
		a.Observe("k", "p")
		c.t = c.t.Add(WindowMaxDays * 24 * time.Hour)
		_ = a.Snapshot() // triggers the epoch close
	}
	snap := a.Snapshot()
	if len(snap.Windows) > MaxEmittedWindows {
		t.Fatalf("emitted %d windows, max %d", len(snap.Windows), MaxEmittedWindows)
	}
	cutoff := c.t.Add(-EmissionRetention)
	for _, w := range snap.Windows {
		if !w.Complete() {
			t.Fatalf("only complete windows may be served: %+v", w)
		}
		end, _ := time.Parse(time.RFC3339, *w.WindowEnd)
		if end.Before(cutoff) {
			t.Fatalf("window older than 90 days emitted: %+v", w)
		}
	}
	// Windows ending at now, -30d, -60d, and exactly -90d (the cutoff is
	// inclusive) are served; older ones are not.
	if len(snap.Windows) != 4 {
		t.Fatalf("expected the 4 complete windows within 90 days, got %d", len(snap.Windows))
	}
}

func TestRandomFailureIsReported(t *testing.T) {
	_, err := New(DefaultParams(), lowerNormalize, WithRandom(io.LimitReader(bytes.NewReader(nil), 0)))
	if err == nil {
		t.Fatalf("expected window key generation failure")
	}
}

func TestEligibilityChangeClosesWindowAndRotatesPolicyID(t *testing.T) {
	a, _ := newTestAggregator(t, DefaultParams(), WithExcludedAccounts([]string{"keepwarm", "canary"}))
	first := openWindow(t, a)
	if len(first.EligibilityPolicyID) != 32 {
		t.Fatalf("eligibility_policy_id = %q", first.EligibilityPolicyID)
	}
	// Same set in a different order / with duplicates: no close, same id.
	if err := a.SetExcludedAccounts([]string{"canary", "keepwarm", "canary"}); err != nil {
		t.Fatal(err)
	}
	if w := openWindow(t, a); w.WindowID != first.WindowID || w.EligibilityPolicyID != first.EligibilityPolicyID {
		t.Fatalf("unchanged policy must not close the window or rotate the id")
	}
	// Different set: close with eligibility_changed and a new random id.
	if err := a.SetExcludedAccounts([]string{"keepwarm"}); err != nil {
		t.Fatal(err)
	}
	if lc := a.LastClose(); lc.Reason != CloseReasonEligibilityChanged || lc.WindowID != first.WindowID {
		t.Fatalf("eligibility_changed close not recorded: %+v", lc)
	}
	if got := a.Snapshot(); len(got.Windows) != 0 {
		t.Fatalf("an incomplete window must not be served: %+v", got.Windows)
	}
	next := openWindow(t, a)
	if next.EligibilityPolicyID == first.EligibilityPolicyID {
		t.Fatalf("policy id must rotate on a set change")
	}
	// The id is random, not a function of the account ids: a fresh
	// aggregator with the identical set gets a different id.
	other, _ := newTestAggregator(t, DefaultParams(), WithExcludedAccounts([]string{"keepwarm"}), WithRandom(&fixedRandom{seed: 99}))
	if openWindow(t, other).EligibilityPolicyID == next.EligibilityPolicyID {
		t.Fatalf("policy id must not be derived from the account ids")
	}
	// canary is eligible again under the new policy.
	a.Observe("k", "canary")
	if openWindow(t, a).EligibleRequestTotal != 1 {
		t.Fatalf("re-included account must contribute under the new window")
	}
}

func TestConfigurationChurnLeavesOneWindowInMemory(t *testing.T) {
	a, _ := newTestAggregator(t, DefaultParams())
	for i := 0; i < 1000; i++ {
		p := DefaultParams()
		p.KeyBuckets = 32 + i%2
		if err := a.SetParams(p); err != nil {
			t.Fatal(err)
		}
		if err := a.SetExcludedAccounts([]string{fmt.Sprintf("acct-%d", i)}); err != nil {
			t.Fatal(err)
		}
	}
	a.mu.Lock()
	retained, open := len(a.closed), a.open != nil
	a.mu.Unlock()
	if retained != 0 || !open {
		t.Fatalf("churn must leave exactly one open window and no retained incomplete windows: retained=%d open=%v", retained, open)
	}
}
