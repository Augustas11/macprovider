package referralapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

// fakeAdvStore drives AdvocacyHandler error branches deterministically.
type fakeAdvStore struct {
	status       auth.ProviderReferral
	statusErr    error
	rateAllowed  bool
	rateErr      error
	challenge    auth.SocialChallenge
	challengeErr error
	replayed     bool
	preflightErr error
	completeErr  error
	failErr      error
	auditErr     error
	failReason   string
	completed    int
	failed       int
	audited      int
}

func (f *fakeAdvStore) ProviderReferralStatus(context.Context, auth.ReferralPolicy, string) (auth.ProviderReferral, error) {
	return f.status, f.statusErr
}
func (f *fakeAdvStore) CreateSocialChallenge(context.Context, auth.ReferralPolicy, string, time.Time) (auth.SocialChallenge, error) {
	return f.challenge, f.challengeErr
}
func (f *fakeAdvStore) PreflightSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, time.Time) (auth.ProviderReferral, bool, error) {
	return f.status, f.replayed, f.preflightErr
}
func (f *fakeAdvStore) CompleteSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, string, string, string, time.Time) (auth.ProviderReferral, error) {
	f.completed++
	return f.status, f.completeErr
}
func (f *fakeAdvStore) FailSocialVerification(_ context.Context, _ auth.ReferralPolicy, _, _, _, _, _, reason string, _ time.Time) (auth.ProviderReferral, error) {
	f.failed++
	f.failReason = reason
	return auth.ProviderReferral{SocialState: "failed"}, f.failErr
}
func (f *fakeAdvStore) ConsumeSocialRateLimit(context.Context, auth.ReferralPolicy, string, string, time.Time, time.Duration, int) (bool, error) {
	return f.rateAllowed, f.rateErr
}
func (f *fakeAdvStore) RecordSocialAudit(context.Context, auth.ReferralPolicy, string, string, string, string, string, string, string, time.Time) error {
	f.audited++
	return f.auditErr
}

func fakeAdvHandler(store *fakeAdvStore, verifier PostVerifier) (*AdvocacyHandler, *advocacyMetrics) {
	metrics := &advocacyMetrics{}
	h := newAdvocacyHandler(nil, "p1", time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC))
	h.Store = store
	h.PostVerifier = verifier
	h.Metrics = metrics
	return &h, metrics
}

func goodVerifyBody() string {
	return `{"post_url":"https://x.com/someone/status/1234567890","challenge":"` + strings.Repeat("a", 64) + `"}`
}

func TestAdvocacyMethodsAndStatusErrors(t *testing.T) {
	store := &fakeAdvStore{rateAllowed: true, status: auth.ProviderReferral{Code: "MAL1-X"}}
	h, metrics := fakeAdvHandler(store, &advocacyVerifier{})
	for name, fn := range map[string]func(http.ResponseWriter, *http.Request){
		"status": h.HandleStatus, "challenge": h.HandleChallenge, "verify": h.HandleVerify,
	} {
		method, want := http.MethodPost, http.MethodGet
		if name != "status" {
			method, want = http.MethodGet, http.MethodPost
		}
		w := httptest.NewRecorder()
		fn(w, bearerRequest(method, "/x", ""))
		if w.Code != http.StatusMethodNotAllowed || w.Header().Get("Allow") != want {
			t.Fatalf("%s wrong method: code=%d allow=%q", name, w.Code, w.Header().Get("Allow"))
		}
	}
	store.statusErr = errors.New("db down")
	w := httptest.NewRecorder()
	h.HandleStatus(w, bearerRequest(http.MethodGet, "/x", ""))
	if w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), "referral_state_unavailable") {
		t.Fatalf("status store error: %d %s", w.Code, w.Body.String())
	}
	store.statusErr = auth.ErrReferralLocked
	w = httptest.NewRecorder()
	h.HandleStatus(w, bearerRequest(http.MethodGet, "/x", ""))
	if w.Code != http.StatusOK || !containsEvent(metrics.events, "status/locked") {
		t.Fatalf("locked status: %d %v", w.Code, metrics.events)
	}
}

func TestAdvocacyChallengeRateLimitAndStoreErrors(t *testing.T) {
	cases := []struct {
		name   string
		store  fakeAdvStore
		code   int
		errMsg string
		retry  string
	}{
		{"rate store error", fakeAdvStore{rateErr: errors.New("x")}, 503, "rate_limit_unavailable", ""},
		{"rate denied", fakeAdvStore{rateAllowed: false}, 429, "rate_limited", "60"},
		{"locked", fakeAdvStore{rateAllowed: true, challengeErr: auth.ErrReferralLocked}, 409, "first_serving_required", ""},
		{"conflict", fakeAdvStore{rateAllowed: true, challengeErr: auth.ErrSocialChallenge}, 409, "challenge_unavailable", ""},
		{"other", fakeAdvStore{rateAllowed: true, challengeErr: errors.New("boom")}, 503, "challenge_unavailable", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := tc.store
			h, _ := fakeAdvHandler(&store, &advocacyVerifier{})
			w := httptest.NewRecorder()
			h.HandleChallenge(w, bearerRequest(http.MethodPost, "/x", ""))
			if w.Code != tc.code || !strings.Contains(w.Body.String(), tc.errMsg) || w.Header().Get("Retry-After") != tc.retry {
				t.Fatalf("got %d retry=%q body=%s", w.Code, w.Header().Get("Retry-After"), w.Body.String())
			}
		})
	}
}

func TestAdvocacyChallengeProviderLimiterBlocks(t *testing.T) {
	store := &fakeAdvStore{rateAllowed: true}
	h, _ := fakeAdvHandler(store, &advocacyVerifier{})
	h.ProviderLimiter = NewBoundedLimiter(1, time.Minute, 8)
	h.ProviderLimiter.Allow("challenge:p1")
	w := httptest.NewRecorder()
	h.HandleChallenge(w, bearerRequest(http.MethodPost, "/x", ""))
	if w.Code != http.StatusTooManyRequests || w.Header().Get("Retry-After") != "60" || !strings.Contains(w.Body.String(), "rate_limited") {
		t.Fatalf("code=%d retry=%q body=%s", w.Code, w.Header().Get("Retry-After"), w.Body.String())
	}
}

func TestAdvocacyVerifyPreVerifierGates(t *testing.T) {
	cases := []struct {
		name   string
		mut    func(*AdvocacyHandler, *fakeAdvStore)
		body   string
		code   int
		errMsg string
	}{
		{"no verifier", func(h *AdvocacyHandler, _ *fakeAdvStore) { h.PostVerifier = nil }, goodVerifyBody(), 404, "social_bonus_disabled"},
		{"provider limiter", func(h *AdvocacyHandler, _ *fakeAdvStore) { h.ProviderLimiter = nil }, goodVerifyBody(), 429, "rate_limited"},
		{"rate error", func(_ *AdvocacyHandler, s *fakeAdvStore) { s.rateErr = errors.New("x") }, goodVerifyBody(), 503, "rate_limit_unavailable"},
		{"rate denied", func(_ *AdvocacyHandler, s *fakeAdvStore) { s.rateAllowed = false }, goodVerifyBody(), 429, "rate_limited"},
		{"short challenge", nil, `{"post_url":"https://x.com/a/status/1","challenge":"abc"}`, 400, "bad_request"},
		{"unknown field", nil, `{"post_url":"u","challenge":"` + strings.Repeat("a", 64) + `","x":1}`, 400, "bad_request"},
		{"bad url", nil, `{"post_url":"https://example.com/a","challenge":"` + strings.Repeat("a", 64) + `"}`, 400, "invalid_post_url"},
		{"challenge invalid", func(_ *AdvocacyHandler, s *fakeAdvStore) { s.preflightErr = auth.ErrSocialChallenge }, goodVerifyBody(), 409, "challenge_invalid"},
		{"preflight error", func(_ *AdvocacyHandler, s *fakeAdvStore) { s.preflightErr = errors.New("x") }, goodVerifyBody(), 503, "verification_state_unavailable"},
		{"no code", func(_ *AdvocacyHandler, s *fakeAdvStore) { s.status.Code = "" }, goodVerifyBody(), 409, "referral_locked"},
		{"bad join base", func(h *AdvocacyHandler, _ *fakeAdvStore) { h.JoinBaseURL = "https://evil.example/j" }, goodVerifyBody(), 500, "verification_config_invalid"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			verifier := &advocacyVerifier{authorID: "42"}
			store := &fakeAdvStore{rateAllowed: true, status: auth.ProviderReferral{Code: "MAL1-ABC"}}
			h, _ := fakeAdvHandler(store, verifier)
			if tc.mut != nil {
				tc.mut(h, store)
			}
			w := httptest.NewRecorder()
			h.HandleVerify(w, bearerRequest(http.MethodPost, "/x", tc.body))
			if w.Code != tc.code || !strings.Contains(w.Body.String(), tc.errMsg) {
				t.Fatalf("got %d %s", w.Code, w.Body.String())
			}
			if verifier.calls != 0 || store.completed != 0 {
				t.Fatalf("external verification ran despite rejection")
			}
		})
	}
}

func TestAdvocacyVerifyOutcomes(t *testing.T) {
	newH := func(v *advocacyVerifier) (*AdvocacyHandler, *fakeAdvStore, *advocacyMetrics) {
		store := &fakeAdvStore{rateAllowed: true, status: auth.ProviderReferral{Code: "MAL1-ABC", SocialState: "pending"}}
		h, m := fakeAdvHandler(store, v)
		return h, store, m
	}
	post := func(h *AdvocacyHandler) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		h.HandleVerify(w, bearerRequest(http.MethodPost, "/x", goodVerifyBody()))
		return w
	}

	// replay short-circuits before the external call
	v := &advocacyVerifier{authorID: "42"}
	h, store, _ := newH(v)
	store.replayed = true
	if w := post(h); w.Code != 200 || v.calls != 0 {
		t.Fatalf("replay: %d calls=%d", w.Code, v.calls)
	}

	// success completes and passes the exact expected URL
	v = &advocacyVerifier{authorID: "42"}
	h, store, m := newH(v)
	if w := post(h); w.Code != 200 || store.completed != 1 || v.postID != "1234567890" ||
		!strings.HasPrefix(v.expectedURL, "https://malibu.tech/j#/MAL1-ABC?c=") || !containsEvent(m.events, "x_verify/pending") {
		t.Fatalf("success: %d completed=%d verifier=%+v", w.Code, store.completed, v)
	}

	// busy slot
	v = &advocacyVerifier{authorID: "42"}
	h, _, _ = newH(v)
	h.VerifySlots <- struct{}{}
	if w := post(h); w.Code != 503 || !strings.Contains(w.Body.String(), "verification_busy") || v.calls != 0 {
		t.Fatalf("busy: %d %s", w.Code, w.Body.String())
	}

	// slot is released after a request
	v = &advocacyVerifier{authorID: "42"}
	h, _, _ = newH(v)
	post(h)
	if len(h.VerifySlots) != 0 {
		t.Fatal("verify slot leaked")
	}

	// transient: audited, Retry-After, no failure recorded
	v = &advocacyVerifier{err: ErrXPostTransient}
	h, store, _ = newH(v)
	if w := post(h); w.Code != 503 || w.Header().Get("Retry-After") != "30" || store.audited != 1 || store.failed != 0 {
		t.Fatalf("transient: %d audited=%d failed=%d", w.Code, store.audited, store.failed)
	}
	// transient with audit failure
	v = &advocacyVerifier{err: ErrXPostTransient}
	h, store, _ = newH(v)
	store.auditErr = errors.New("x")
	if w := post(h); w.Code != 503 || !strings.Contains(w.Body.String(), "verification_audit_unavailable") || w.Header().Get("Retry-After") != "" {
		t.Fatalf("audit err: %d %s", w.Code, w.Body.String())
	}

	// terminal failure -> 422 with state, reason post_not_verified
	v = &advocacyVerifier{err: ErrXPostTerminal}
	h, store, _ = newH(v)
	if w := post(h); w.Code != 422 || !strings.Contains(w.Body.String(), `"social_state":"failed"`) || store.failReason != "post_not_verified" || store.completed != 0 {
		t.Fatalf("terminal: %d %s reason=%s", w.Code, w.Body.String(), store.failReason)
	}
	// blank author id with no error -> author_missing, never completes
	v = &advocacyVerifier{authorID: "  "}
	h, store, _ = newH(v)
	if w := post(h); w.Code != 422 || store.failReason != "author_missing" || store.completed != 0 {
		t.Fatalf("blank author: %d reason=%s completed=%d", w.Code, store.failReason, store.completed)
	}
	// failure recording error
	v = &advocacyVerifier{err: ErrXPostTerminal}
	h, store, _ = newH(v)
	store.failErr = errors.New("x")
	if w := post(h); w.Code != 503 {
		t.Fatalf("fail err: %d", w.Code)
	}

	// complete errors
	v = &advocacyVerifier{authorID: "42"}
	h, store, _ = newH(v)
	store.completeErr = auth.ErrSocialChallenge
	if w := post(h); w.Code != 409 || !strings.Contains(w.Body.String(), "challenge_invalid") {
		t.Fatalf("complete conflict: %d", w.Code)
	}
	store.completeErr = errors.New("x")
	if w := post(h); w.Code != 503 {
		t.Fatalf("complete err: %d", w.Code)
	}
}

func TestAdvocacyNowDefaultsToWallClock(t *testing.T) {
	h := AdvocacyHandler{}
	before := time.Now().UTC().Add(-time.Second)
	if got := h.now(); got.Before(before) || got.Location() != time.UTC {
		t.Fatalf("now=%v", got)
	}
	v := ValidationHandler{}
	if got := v.now(); got.Before(before) || got.Location() != time.UTC {
		t.Fatalf("validation now=%v", got)
	}
}

type fakeServingSource struct {
	pages  [][]VerifiedServing
	afters []string
	err    error
}

func (f *fakeServingSource) ListVerifiedServing(_ context.Context, after string, _ int) ([]VerifiedServing, error) {
	f.afters = append(f.afters, after)
	if f.err != nil {
		return nil, f.err
	}
	if len(f.afters) > len(f.pages) {
		return nil, nil
	}
	return f.pages[len(f.afters)-1], nil
}

type fakeQualifier struct {
	seen    []string
	created map[string]bool
	errOn   string
}

func (f *fakeQualifier) QualifyProviderReferral(_ context.Context, _ auth.ReferralPolicy, id, evidence string, _, _ time.Time) (auth.ProviderReferral, bool, error) {
	if id == f.errOn {
		return auth.ProviderReferral{}, false, errors.New("boom")
	}
	f.seen = append(f.seen, id+"|"+evidence)
	return auth.ProviderReferral{}, f.created[id], nil
}

func TestServingReconcilerPaginatesCountsAndSkipsBlank(t *testing.T) {
	src := &fakeServingSource{pages: [][]VerifiedServing{
		{{ProviderID: "a", EvidenceID: "e1"}, {ProviderID: " ", EvidenceID: "e2"}},
		{{ProviderID: "b", EvidenceID: "e3"}, {ProviderID: "c", EvidenceID: "e4"}},
		{{ProviderID: "d", EvidenceID: "e5"}},
	}}
	q := &fakeQualifier{created: map[string]bool{"a": true, "c": true}}
	r := ServingReconciler{Source: src, Store: q, BatchSize: 2, Now: func() time.Time { return time.Unix(1, 0) }}
	n, err := r.Reconcile(context.Background())
	if err != nil || n != 2 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if strings.Join(q.seen, ",") != "a|e1,b|e3,c|e4,d|e5" {
		t.Fatalf("seen=%v", q.seen)
	}
	if strings.Join(src.afters, ",") != ",a,c" {
		t.Fatalf("cursor=%q", src.afters)
	}

	q = &fakeQualifier{created: map[string]bool{"a": true}, errOn: "b"}
	src = &fakeServingSource{pages: [][]VerifiedServing{{{ProviderID: "a"}, {ProviderID: "b"}}}}
	n, err = ServingReconciler{Source: src, Store: q}.Reconcile(context.Background())
	if err == nil || n != 1 {
		t.Fatalf("qualify error: n=%d err=%v", n, err)
	}
	src = &fakeServingSource{err: errors.New("x")}
	if n, err = (ServingReconciler{Source: src, Store: q}).Reconcile(context.Background()); err == nil || n != 0 {
		t.Fatalf("source error: n=%d err=%v", n, err)
	}
	if n, err = (ServingReconciler{}).Reconcile(context.Background()); n != 0 || err != nil {
		t.Fatalf("nil deps: %d %v", n, err)
	}
}

func TestSQLiteServingEvidenceBlankPathAndMissingDB(t *testing.T) {
	items, err := SQLiteServingEvidence{Path: "  "}.ListVerifiedServing(context.Background(), "", 10)
	if err != nil || items != nil {
		t.Fatalf("blank path: %v %v", items, err)
	}
	_, err = SQLiteServingEvidence{Path: t.TempDir() + "/missing.db"}.ListVerifiedServing(context.Background(), "", 0)
	if err == nil {
		t.Fatal("expected error for missing read-only database")
	}
}

func TestDecodeBoundedJSONRejectsOversizeAndTrailingValues(t *testing.T) {
	type req struct {
		A string `json:"a"`
	}
	for name, tc := range map[string]struct {
		body string
		ok   bool
	}{
		"ok":       {`{"a":"x"}`, true},
		"oversize": {`{"a":"` + strings.Repeat("x", 40) + `"}`, false},
		// first max+1 bytes are valid JSON; only the explicit size check rejects it
		"oversize padded": {`{"a":"x"}` + strings.Repeat(" ", 40), false},
		"trailing":        {`{"a":"x"}{"a":"y"}`, false},
		"unknown":         {`{"b":1}`, false},
		"garbage":         {`nope`, false},
	} {
		var dst req
		err := decodeBoundedJSON(httptest.NewRequest(http.MethodPost, "/", strings.NewReader(tc.body)), &dst, 30)
		if (err == nil) != tc.ok {
			t.Fatalf("%s: err=%v", name, err)
		}
	}
}

func TestReferralReasonMapsEveryAuthError(t *testing.T) {
	for err, want := range map[error]string{
		auth.ErrReferralRequired:  "missing",
		auth.ErrReferralExpired:   "expired",
		auth.ErrReferralRevoked:   "revoked",
		auth.ErrReferralExhausted: "exhausted",
		auth.ErrReferralConflict:  "conflict",
		errors.New("other"):       "invalid",
	} {
		if got := referralReason(err); got != want {
			t.Fatalf("%v -> %q want %q", err, got, want)
		}
	}
}

func TestOnlyContentTypeRequested(t *testing.T) {
	for _, tc := range []struct {
		in   []string
		want bool
	}{
		{nil, true},
		{[]string{"Content-Type"}, true},
		{[]string{" content-type , "}, true},
		{[]string{"content-type", "x-other"}, false},
		{[]string{"content-type,authorization"}, false},
		{[]string{"authorization"}, false},
		{[]string{" , "}, false},
	} {
		if got := onlyContentTypeRequested(tc.in); got != tc.want {
			t.Fatalf("%q -> %v", tc.in, got)
		}
	}
}

func TestBoundedLimiterWindowsEvictionAndDegenerateConfig(t *testing.T) {
	now := time.Unix(1000, 0)
	l := NewBoundedLimiter(2, time.Minute, 2)
	l.now = func() time.Time { return now }
	if !l.Allow("a") || !l.Allow("a") || l.Allow("a") {
		t.Fatal("limit of 2 not enforced")
	}
	if !l.Allow("b") {
		t.Fatal("b should be admitted")
	}
	if l.Allow("c") {
		t.Fatal("full table must reject new keys without evicting active callers")
	}
	if l.Allow("a") {
		t.Fatal("a budget must not reset when table is full")
	}
	now = now.Add(time.Minute)
	if !l.Allow("a") || !l.Allow("c") {
		t.Fatal("expired windows should be reclaimed")
	}
	for _, bad := range []*BoundedLimiter{nil, NewBoundedLimiter(0, time.Minute, 1), NewBoundedLimiter(1, 0, 1), NewBoundedLimiter(1, time.Minute, 0)} {
		if bad.Allow("k") {
			t.Fatal("degenerate limiter must deny")
		}
	}
}

func TestShareURLDigestRequiresCanonicalJoinBase(t *testing.T) {
	ch := strings.Repeat("b", 64)
	url1 := fragmentShareURL("https://malibu.tech/j", "MAL1-X", ch)
	d1, err := ShareURLDigest(url1, "https://malibu.tech/j")
	if err != nil || len(d1) != 64 {
		t.Fatalf("digest=%q err=%v", d1, err)
	}
	d2, _ := ShareURLDigest(fragmentShareURL("https://malibu.tech/j", "MAL1-Y", ch), "https://malibu.tech/j")
	if d1 == d2 {
		t.Fatal("different codes must yield different digests")
	}
	if _, err := ShareURLDigest(url1, "https://other.example/j"); err == nil {
		t.Fatal("non-canonical join base accepted")
	}
	// share URL and base agree with each other but are not the canonical base
	for _, base := range []string{"https://other.example/j", "https://malibu.tech/j/", "http://malibu.tech/j"} {
		if _, err := ShareURLDigest(fragmentShareURL(base, "MAL1-X", ch), base); err == nil {
			t.Fatalf("non-canonical join base %q accepted", base)
		}
	}
	if _, err := ShareURLDigest("https://malibu.tech/j#/MAL1-X?c=short", "https://malibu.tech/j"); err == nil {
		t.Fatal("bad challenge accepted")
	}
}

func TestRecheckPostRejectsMalformedDigestWithoutNetwork(t *testing.T) {
	c := &XAPIClient{}
	_, err := c.RecheckPost(context.Background(), "1", "not-a-digest")
	if !errors.Is(err, ErrXPostTerminal) {
		t.Fatalf("err=%v", err)
	}
}

func TestDescribesProtectedOrPrivatePost(t *testing.T) {
	for body, want := range map[string]bool{
		`{"type":"https://api.x.com/2/problems/not-authorized-for-resource"}`:              true,
		`{"errors":[{"type":"https://api.x.com/2/problems/not-authorized-for-resource"}]}`: true,
		`{"errors":[{"code":179}]}`: true,
		`{"errors":[{"code":88}]}`:  false,
		`not json`:                  false,
		`{}`:                        false,
	} {
		if got := describesProtectedOrPrivatePost([]byte(body)); got != want {
			t.Fatalf("%s -> %v", body, got)
		}
	}
}
