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

const (
	policyA = "9a2e6c1d4b8f0a3e5c7d9b1f3a5c7e90"
	policyB = "1111111111111111111111111111aaaa"
)

func newTestAggregator(t *testing.T, params Params, opts ...Option) (*Aggregator, *clock) {
	t.Helper()
	c := &clock{t: time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)}
	opts = append([]Option{WithClock(c.now), WithRandom(&fixedRandom{seed: 1}), WithPolicy(policyA, 2)}, opts...)
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
	if len(um.Windows) != 1 || um.Windows[0].WindowEnd != nil {
		t.Fatalf("no open window in dump: %+v", um)
	}
	return um.Windows[0]
}

// otherSuppressed reads the open window's internal counters (the wire form
// carries no eligible_request_total).
func openState(t *testing.T, a *Aggregator) (eligible uint64, other OtherSuppressed, entries int) {
	t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.open == nil {
		t.Fatalf("no open window")
	}
	return a.open.eligible, a.open.other, len(a.open.entries)
}

// lowFloor makes the floor rule inert so the S-order tests can inspect
// per-key bounds; the floor rule has its own test.
func lowFloor() Params {
	p := DefaultParams()
	p.BuyerRequestFloor = 100
	p.PrincipalCapPct = 10 // cap 10 per principal
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
	if err := bad.Validate(); err == nil {
		t.Fatalf("expected floor×pct/100 < 1 to be rejected")
	}
	bad = DefaultParams()
	bad.PrincipalCapPct = 20
	if err := bad.Validate(); err == nil {
		t.Fatalf("a cap above a tenth of the floor must be rejected")
	}
	bad = DefaultParams()
	bad.KeyBuckets = MaxKeyBuckets + 1
	if err := bad.Validate(); err == nil {
		t.Fatalf("key_buckets above the maximum must be rejected")
	}
	if got := DefaultParams().PrincipalCapRequests(); got != 25 {
		t.Fatalf("PrincipalCapRequests = %d, want 25", got)
	}
	if _, err := New(DefaultParams(), lowerNormalize, WithPolicy("short", 0)); err == nil {
		t.Fatalf("a malformed policy id must be rejected")
	}
}

func TestS1EmptyPrincipalContributesToNothing(t *testing.T) {
	a, _ := newTestAggregator(t, DefaultParams())
	a.Observe("qwen3-14b", "")
	eligible, other, entries := openState(t, a)
	if eligible != 0 || entries != 0 || other.RequestCount != 0 {
		t.Fatalf("an unauthenticated request contributed: eligible=%d entries=%d other=%+v", eligible, entries, other)
	}
}

func TestS3GrammarGoesToOtherSuppressedOnly(t *testing.T) {
	a, _ := newTestAggregator(t, lowFloor())
	a.Observe("Qwen 3 14B!", "acct-1")            // space and '!' out of grammar
	a.Observe(strings.Repeat("a", 129), "acct-1") // over 128 bytes
	a.Observe("ünicode", "acct-1")                // non-ASCII
	a.Observe(strings.Repeat("a", 128), "acct-1") // exactly 128: eligible
	eligible, other, entries := openState(t, a)
	if eligible != 4 {
		t.Fatalf("eligible = %d, want 4", eligible)
	}
	if other.RequestCount != 3 || other.DistinctKeyCount != 3 {
		t.Fatalf("other_suppressed = %+v, want 3/3", other)
	}
	if entries != 1 {
		t.Fatalf("entries = %d, want the one eligible key", entries)
	}
	// The eligible key was requested by one principal below the floor:
	// retained but omitted from the wire (SPEC-017 §5.2b.4).
	w := openWindow(t, a)
	if len(w.Buckets) != 0 || w.SuppressedBucketCount != 1 {
		t.Fatalf("buckets = %+v suppressed=%d, want 0 emitted / 1 suppressed", w.Buckets, w.SuppressedBucketCount)
	}
	// Ten principals at the cap clear the floor of 100 → emitted.
	for i := 0; i < 10; i++ {
		for j := 0; j < 10; j++ {
			a.Observe(strings.Repeat("a", 128), fmt.Sprintf("acct-%d", i+2))
		}
	}
	w = openWindow(t, a)
	if len(w.Buckets) != 1 || w.Buckets[0].ModelKey != strings.Repeat("a", 128) || w.SuppressedBucketCount != 0 || w.Buckets[0].LowerBound != 101 {
		t.Fatalf("ten principals clearing the floor should emit the bucket: %+v suppressed=%d", w.Buckets, w.SuppressedBucketCount)
	}
}

func TestS4PrincipalCapAndFloorGatedEmission(t *testing.T) {
	p := DefaultParams() // cap 25, floor 250
	a, _ := newTestAggregator(t, p)
	for i := 0; i < 40; i++ {
		a.Observe("qwen3-14b", "single-buyer")
	}
	w := openWindow(t, a)
	if _, ok := bucketFor(w, "qwen3-14b"); ok || w.SuppressedBucketCount != 1 {
		t.Fatalf("single-principal bucket must be omitted: %+v suppressed=%d", w.Buckets, w.SuppressedBucketCount)
	}
	if _, other, _ := openState(t, a); other.RequestCount != 15 {
		t.Fatalf("over-cap traffic not discarded into other_suppressed: %+v", other)
	}
	dump, _ := a.DiagnosticDump()
	if bytes.Contains(dump, []byte("qwen3-14b")) {
		t.Fatalf("a key requested by one principal must not appear in emitted bytes: %s", dump)
	}
	// Three principals but a lower bound of 27: still below the floor.
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
	// 249 does not clear 250.
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
	p.PrincipalsPerBucket = 10
	a, _ := newTestAggregator(t, p)
	for i := 0; i < 10; i++ {
		for j := 0; j < 10; j++ {
			a.Observe("k", fmt.Sprintf("p%d", i))
		}
	}
	a.Observe("k", "p-overflow")
	w := openWindow(t, a)
	b, ok := bucketFor(w, "k")
	if !ok || b.LowerBound != 100 {
		t.Fatalf("bucket = %+v, want lower_bound 100 (overflow principal excluded)", b)
	}
	if _, other, _ := openState(t, a); other.RequestCount != 1 {
		t.Fatalf("overflow principal not routed to other_suppressed: %+v", other)
	}
}

func TestS5EvictionIsDeterministicAndTransfersOnce(t *testing.T) {
	p := lowFloor()
	p.KeyBuckets = 2
	run := func() (UnmatchedModels, OtherSuppressed, int) {
		a, _ := newTestAggregator(t, p)
		for i := 0; i < 10; i++ {
			for j := 0; j < 10; j++ {
				a.Observe("alpha", fmt.Sprintf("a%d", i))
			}
		}
		for i := 0; i < 3; i++ {
			a.Observe("beta", fmt.Sprintf("b%d", i))
		}
		// Summary full: gamma evicts beta (count 3) -> count 4, error 3.
		a.Observe("gamma", "g0")
		// delta evicts gamma (count 4 < alpha 100) -> count 5, error 4; only
		// gamma's non-inherited contribution (4-3 = 1) transfers.
		a.Observe("delta", "d0")
		dump, _ := a.DiagnosticDump()
		var um UnmatchedModels
		_ = json.Unmarshal(dump, &um)
		_, other, entries := openState(t, a)
		return um, other, entries
	}
	s1, other, entries := run()
	s2, _, _ := run()
	j1, _ := json.Marshal(s1)
	j2, _ := json.Marshal(s2)
	if !bytes.Equal(j1, j2) {
		t.Fatalf("two runs over one request order differ:\n%s\n%s", j1, j2)
	}
	w := s1.Windows[0]
	if len(w.Buckets) != 1 || w.Buckets[0].ModelKey != "alpha" || w.Buckets[0].LowerBound != 100 || w.SuppressedBucketCount != 1 {
		t.Fatalf("emitted = %+v suppressed=%d, want alpha only", w.Buckets, w.SuppressedBucketCount)
	}
	if other.RequestCount != 3+1 {
		t.Fatalf("eviction transfer = %d, want beta 3 + gamma non-inherited 1", other.RequestCount)
	}
	if other.DistinctKeyCount != 2 || entries != 2 {
		t.Fatalf("distinct_key_count = %d entries = %d, want 2/2", other.DistinctKeyCount, entries)
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
	_, other, _ := openState(t, a)
	if !other.DistinctKeyCountSaturated || other.DistinctKeyCount != uint64(p.DistinctKeyCap) {
		t.Fatalf("distinct_key_count should saturate at the cap with its own flag: %+v", other)
	}
	if other.RequestCountSaturated {
		t.Fatalf("request_count must not be flagged saturated: %+v", other)
	}
}

func TestMemoryBoundedUnderDistinctPrincipalFanout(t *testing.T) {
	p := lowFloor() // floor 100, cap 10
	a, _ := newTestAggregator(t, p)
	// The first 64 principals fill the bucket's table at the cap.
	for i := 0; i < p.PrincipalsPerBucket; i++ {
		for j := 0; j < 10; j++ {
			a.Observe("one-key", fmt.Sprintf("tracked-%d", i))
		}
	}
	// A flood of distinct principals overflows the table: none is tracked.
	for i := 0; i < 200_000; i++ {
		a.Observe("one-key", fmt.Sprintf("acct-%d", i))
	}
	a.mu.Lock()
	tracked := len(a.open.entries[0].principals)
	a.mu.Unlock()
	if tracked != p.PrincipalsPerBucket {
		t.Fatalf("tracked principals = %d, want %d", tracked, p.PrincipalsPerBucket)
	}
	b, ok := bucketFor(openWindow(t, a), "one-key")
	if !ok || b.LowerBound != uint64(p.PrincipalsPerBucket*10) {
		t.Fatalf("overflow principals must not count: %+v", b)
	}
	if _, other, _ := openState(t, a); other.RequestCount != 200_000 {
		t.Fatalf("overflow traffic not in other_suppressed: %+v", other)
	}
}

func TestRawPrincipalIsTransientAndDumpIsOnlyTheOpenWindow(t *testing.T) {
	a, _ := newTestAggregator(t, DefaultParams())
	const raw = "buyer-account-SECRET-7f3a"
	a.Observe("qwen3-14b", raw)
	a.Observe("bad key!", raw)
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
	if len(um.Windows) != 1 || um.Windows[0].WindowEnd != nil || um.Windows[0].EligibilityPolicyID != policyA {
		t.Fatalf("dump must hold exactly the open window with its policy: %+v", um.Windows)
	}
	var wireKeys map[string]json.RawMessage
	_ = json.Unmarshal(obj["windows"], &[]map[string]json.RawMessage{})
	var windows []map[string]json.RawMessage
	_ = json.Unmarshal(obj["windows"], &windows)
	wireKeys = windows[0]
	for _, forbidden := range []string{"close_reason", "eligible_request_total", "closed", "complete"} {
		if _, present := wireKeys[forbidden]; present {
			t.Fatalf("wire window must not carry %q", forbidden)
		}
	}
	if len(a.Snapshot().Windows) != 0 {
		t.Fatalf("the served snapshot must never carry the open window")
	}
	// No aggregator state holds the raw id either.
	a.mu.Lock()
	var state bytes.Buffer
	fmt.Fprintf(&state, "%v %v %v %d", a.open.index, a.open.entries, a.policyID, a.policyCount)
	for _, e := range a.open.entries {
		fmt.Fprintf(&state, "%v", e.principals)
	}
	a.mu.Unlock()
	if bytes.Contains(state.Bytes(), []byte(raw)) {
		t.Fatalf("aggregator state holds the raw principal")
	}
}

func TestWindowsCloseExactlyAtTheDeadlineAndOnlyCompleteOnesAreServed(t *testing.T) {
	a, c := newTestAggregator(t, DefaultParams())
	a.Observe("k1", "p")
	first := openWindow(t, a)
	if first.Parameters.KAnonymityMin != KAnonymityMin || first.Parameters.KeyBuckets != 64 || first.Parameters.PrincipalCapPct != 10 || first.Parameters.PrincipalCapRequests != 25 {
		t.Fatalf("window parameters = %+v", first.Parameters)
	}
	// Parameter change closes with parameters_changed: incomplete, never
	// served, destroyed.
	p := DefaultParams()
	p.KeyBuckets = 32
	if err := a.SetParams(p); err != nil {
		t.Fatal(err)
	}
	if got := a.Snapshot(); len(got.Windows) != 0 {
		t.Fatalf("an incomplete window must not be served: %+v", got.Windows)
	}
	if lc := a.LastClose(); lc.Reason != CloseReasonParametersChanged || lc.WindowID != first.WindowID {
		t.Fatalf("last close record = %+v", lc)
	}
	second := openWindow(t, a)
	if second.WindowID == first.WindowID || second.Parameters.KeyBuckets != 32 {
		t.Fatalf("new window not opened with new parameters: %+v", second)
	}
	// A tick arriving 5 days late closes the epoch at exactly start + 30d and
	// opens the next one at that deadline.
	start, _ := time.Parse(time.RFC3339, second.WindowStart)
	c.t = start.Add(35 * 24 * time.Hour)
	a.Observe("k2", "p")
	snap := a.Snapshot()
	if len(snap.Windows) != 1 || snap.Windows[0].WindowID != second.WindowID || !snap.Windows[0].Complete() {
		t.Fatalf("epoch_elapsed window not served as complete: %+v", snap.Windows)
	}
	if got := *snap.Windows[0].WindowEnd; got != start.Add(30*24*time.Hour).Format(time.RFC3339) {
		t.Fatalf("window_end = %s, want the exact deadline", got)
	}
	third := openWindow(t, a)
	if third.WindowStart != start.Add(30*24*time.Hour).Format(time.RFC3339) {
		t.Fatalf("next window must open at the deadline: %s", third.WindowStart)
	}
	if err := ValidateWindow(snap.Windows[0]); err != nil {
		t.Fatalf("served window must validate: %v", err)
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

func TestEmissionBoundedToThreeWindowsAndNinetyDays(t *testing.T) {
	a, c := newTestAggregator(t, DefaultParams())
	for i := 0; i < 12; i++ {
		a.Observe("k", "p")
		c.t = c.t.Add(WindowMaxDays * 24 * time.Hour)
		_ = a.Snapshot() // triggers the epoch close
	}
	snap := a.Snapshot()
	if len(snap.Windows) != MaxEmittedWindows {
		t.Fatalf("emitted %d windows, want %d", len(snap.Windows), MaxEmittedWindows)
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
}

func TestEligibilityPolicyChangeClosesWindow(t *testing.T) {
	a, _ := newTestAggregator(t, DefaultParams())
	first := openWindow(t, a)
	if err := a.SetPolicy(policyA, 2); err != nil {
		t.Fatal(err)
	}
	if w := openWindow(t, a); w.WindowID != first.WindowID {
		t.Fatalf("an unchanged policy must not close the window")
	}
	if err := a.SetPolicy(policyB, 1); err != nil {
		t.Fatal(err)
	}
	if lc := a.LastClose(); lc.Reason != CloseReasonEligibilityChanged || lc.WindowID != first.WindowID {
		t.Fatalf("eligibility_changed close not recorded: %+v", lc)
	}
	next := openWindow(t, a)
	if next.EligibilityPolicyID != policyB {
		t.Fatalf("new window must carry the new policy: %+v", next)
	}
	if err := a.SetPolicy("nope", 0); err == nil {
		t.Fatalf("a malformed policy id must be rejected")
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
		if err := a.SetPolicy(fmt.Sprintf("%032x", i), i); err != nil {
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

func TestValidateWindowRejectsMalformedPersistedWindows(t *testing.T) {
	a, c := newTestAggregator(t, DefaultParams())
	for i := 0; i < 10; i++ {
		for j := 0; j < 25; j++ {
			a.Observe("qwen3-14b", fmt.Sprintf("b%d", i))
		}
	}
	c.t = c.t.Add(WindowMaxDays * 24 * time.Hour)
	good := a.Snapshot().Windows[0]
	if err := ValidateWindow(good); err != nil {
		t.Fatalf("good window rejected: %v", err)
	}
	cases := map[string]func(w *Window){
		"sub-floor bucket":    func(w *Window) { w.Buckets[0].LowerBound, w.Buckets[0].Count = 10, 10 },
		"bound arithmetic":    func(w *Window) { w.Buckets[0].Error = 1 },
		"bad key":             func(w *Window) { w.Buckets[0].ModelKey = "Not A Key" },
		"open window":         func(w *Window) { w.WindowEnd = nil },
		"short epoch":         func(w *Window) { e := c.t.Add(-time.Hour).Format(time.RFC3339); w.WindowEnd = &e },
		"wrong k":             func(w *Window) { w.Parameters.KAnonymityMin = 5 },
		"cap mismatch":        func(w *Window) { w.Parameters.PrincipalCapRequests = 26 },
		"too many buckets":    func(w *Window) { w.SuppressedBucketCount = 64 },
		"bad policy id":       func(w *Window) { w.EligibilityPolicyID = "x" },
		"negative counter":    func(w *Window) { w.SuppressedBucketCount = -1 },
		"other beyond cap":    func(w *Window) { w.OtherSuppressed.DistinctKeyCount = 10001 },
		"duplicate bucket":    func(w *Window) { w.Buckets = append(w.Buckets, w.Buckets[0]) },
		"unordered buckets":   func(w *Window) { w.Buckets = append(w.Buckets, Bucket{ModelKey: "zzz", LowerBound: 300, Count: 300}) },
		"out of bounds param": func(w *Window) { w.Parameters.KeyBuckets = 0 },
	}
	for name, mutate := range cases {
		w := cloneWindow(good)
		mutate(&w)
		if err := ValidateWindow(w); err == nil {
			t.Fatalf("%s: malformed window accepted", name)
		}
	}
}

func TestRandomFailureIsReported(t *testing.T) {
	_, err := New(DefaultParams(), lowerNormalize, WithPolicy(policyA, 0), WithRandom(io.LimitReader(bytes.NewReader(nil), 0)))
	if err == nil {
		t.Fatalf("expected window key generation failure")
	}
}
