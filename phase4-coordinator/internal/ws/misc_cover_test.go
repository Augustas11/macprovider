package ws

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/canarycorr"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

func TestCanaryMetricsFromTiming(t *testing.T) {
	t.Parallel()
	start := time.Unix(1000, 0)
	first := start.Add(200 * time.Millisecond)
	done := start.Add(1200 * time.Millisecond)
	m := canaryMetricsFromTiming(start, first, done, 50)
	if m.TTFTMS != 200 || !m.LatencyGated {
		t.Fatalf("ttft=%d gated=%v", m.TTFTMS, m.LatencyGated)
	}
	if m.SustainedTPS < 49.9 || m.SustainedTPS > 50.1 {
		t.Fatalf("tps=%v want 50 (50 tokens over 1s decode)", m.SustainedTPS)
	}
	// No first token: TTFT is full duration, tokens clamp to 1.
	m = canaryMetricsFromTiming(start, time.Time{}, done, 0)
	if m.TTFTMS != 1200 {
		t.Fatalf("ttft without first token=%d", m.TTFTMS)
	}
	if m.SustainedTPS < 0.83 || m.SustainedTPS > 0.84 {
		t.Fatalf("tps=%v want 1/1.2", m.SustainedTPS)
	}
	// Zero decode window is floored at 1ms.
	m = canaryMetricsFromTiming(start, done, done, 2)
	if m.SustainedTPS < 1999 || m.SustainedTPS > 2001 {
		t.Fatalf("tps=%v want 2000", m.SustainedTPS)
	}
}

func TestCanaryCompletionTokens(t *testing.T) {
	t.Parallel()
	if got := canaryCompletionTokens([]byte(`{"usage":{"completion_tokens":17}}`)); got != 17 {
		t.Fatalf("got %d", got)
	}
	if got := canaryCompletionTokens([]byte(`not json`)); got != 0 {
		t.Fatalf("bad json got %d", got)
	}
	if got := canaryCompletionTokens([]byte(`{}`)); got != 0 {
		t.Fatalf("missing usage got %d", got)
	}
}

func TestClassToFailReason(t *testing.T) {
	t.Parallel()
	cases := map[canarycorr.FailureClass]canaryFailReason{
		canarycorr.ClassNonceMismatch: canaryFailNonce,
		canarycorr.ClassIncomplete:    canaryFailIncomplete,
		canarycorr.ClassRelayHard:     canaryFailRelay,
		canarycorr.ClassPass:          canaryFailNone,
	}
	for class, want := range cases {
		if got := classToFailReason(class); got != want {
			t.Errorf("class %q: got %q want %q", class, got, want)
		}
	}
}

func TestSharedCanaryDispatchTakeAndRequeue(t *testing.T) {
	t.Parallel()
	now := time.Unix(5000, 0)
	s := &Server{now: func() time.Time { return now }}
	if _, ok := s.takeSharedCanaryDispatch("p1"); ok {
		t.Fatal("take on empty map must miss")
	}
	s.requeueSharedCanaryDispatch("  ", sharedCanaryDispatch{modelID: "ignored"})
	if s.canarySharedDispatch != nil {
		t.Fatal("blank provider id must not be queued")
	}
	s.requeueSharedCanaryDispatch("p1", sharedCanaryDispatch{modelID: "m", fingerprint: "fp", bankGeneration: 3})
	due, ok := s.canaryDue.Load("p1")
	if !ok || !due.(time.Time).Equal(now) {
		t.Fatalf("requeue must mark provider due now, got %v %v", due, ok)
	}
	if _, ok := s.takeSharedCanaryDispatch("p2"); ok {
		t.Fatal("other provider must miss")
	}
	d, ok := s.takeSharedCanaryDispatch("p1")
	if !ok || d.modelID != "m" || d.fingerprint != "fp" || d.bankGeneration != 3 {
		t.Fatalf("take = %+v ok=%v", d, ok)
	}
	if _, ok := s.takeSharedCanaryDispatch("p1"); ok {
		t.Fatal("take must clear the entry")
	}
}

func TestAllowAnonymousEventCapsPerWindow(t *testing.T) {
	t.Parallel()
	var nilServer *Server
	if nilServer.allowAnonymousEvent() {
		t.Fatal("nil server must deny")
	}
	s := &Server{}
	for i := 0; i < anonymousEventsPerMinute; i++ {
		if !s.allowAnonymousEvent() {
			t.Fatalf("event %d denied under cap", i)
		}
	}
	if s.allowAnonymousEvent() {
		t.Fatal("event over cap must be denied")
	}
	// Window expiry resets the counter.
	s.anonymousEventWindow = time.Now().UTC().Add(-2 * time.Minute)
	if !s.allowAnonymousEvent() {
		t.Fatal("new window must allow")
	}
}

func TestParseDrainStatusValidation(t *testing.T) {
	t.Parallel()
	ok, field, err := ParseDrainStatus([]byte(`{"type":"drain_status","phase":"in_progress","inflight_requests":2,"estimated_drain_seconds":9}`))
	if err != nil || field != "" || ok.Phase != "in_progress" || ok.InflightRequests != 2 || ok.EstimatedDrainSeconds != 9 {
		t.Fatalf("valid: %+v %q %v", ok, field, err)
	}
	bad := map[string]string{
		`{`:                                 "json",
		`{"type":"nak","phase":"starting"}`: "type",
		`{"type":"drain_status","phase":"bogus"}`:                                 "phase",
		`{"type":"drain_status","phase":"starting","inflight_requests":-1}`:       "inflight_requests",
		`{"type":"drain_status","phase":"starting","estimated_drain_seconds":-1}`: "estimated_drain_seconds",
	}
	for payload, wantField := range bad {
		if _, field, err := ParseDrainStatus([]byte(payload)); err == nil || field != wantField {
			t.Errorf("%s: field=%q err=%v want field %q", payload, field, err, wantField)
		}
	}
}

func TestParseNakRejectsBadFields(t *testing.T) {
	t.Parallel()
	bad := map[string]string{
		`{`: "json",
		`{"type":"x","in_reply_to":"a","error":{"code":"c"}}`:                       "type",
		`{"type":"nak","error":{"code":"c"}}`:                                       "in_reply_to",
		`{"type":"nak","in_reply_to":"a","error":{}}`:                               "error.code",
		`{"type":"nak","in_reply_to":"a\u001b[2J","error":{"code":"c"}}`:            "in_reply_to",
		`{"type":"nak","in_reply_to":"a","error":{"code":"c\u0007"}}`:               "error.code",
		`{"type":"nak","in_reply_to":"a","error":{"code":"c","message":"m\u001b"}}`: "error.message",
	}
	for payload, wantField := range bad {
		if _, field, err := ParseNak([]byte(payload)); err == nil || field != wantField {
			t.Errorf("%s: field=%q err=%v want field %q", payload, field, err, wantField)
		}
	}
}

func TestParseRelayBlindKeyRecordsEdges(t *testing.T) {
	t.Parallel()
	raw := func(s string) map[string]json.RawMessage {
		var m map[string]json.RawMessage
		if err := json.Unmarshal([]byte(s), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	if field, err := parseRelayBlindKeyRecords(raw(`{}`), new([]relayblind.KeyRecord)); field != "" || err != nil {
		t.Fatalf("absent: %q %v", field, err)
	}
	for _, in := range []string{
		`{"relay_blind_key_records":null}`,
		`{"relay_blind_key_records":"x"}`,
		`{"relay_blind_key_records":[{}]}`,
	} {
		if field, err := parseRelayBlindKeyRecords(raw(in), new([]relayblind.KeyRecord)); field != "relay_blind_key_records" || err == nil {
			t.Errorf("%s: field=%q err=%v", in, field, err)
		}
	}
	tooMany := `{"relay_blind_key_records":[` + strings.Repeat("{},", relayblind.MaxModelCount) + `{}]}`
	if field, err := parseRelayBlindKeyRecords(raw(tooMany), new([]relayblind.KeyRecord)); field != "relay_blind_key_records" || err == nil {
		t.Errorf("too many: field=%q err=%v", field, err)
	}
}
