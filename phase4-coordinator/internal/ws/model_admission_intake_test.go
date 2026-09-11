package ws

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
)

// intakeTrustStore is a HardwareTrustAdminStore whose only live method is
// the SPEC-047 R009 trust-state read.
type intakeTrustStore struct {
	held   map[string]bool
	active map[string]bool
	err    error
}

func (s *intakeTrustStore) RequestHardwareTrustApproval(context.Context, string, int64, string, *time.Time, string, string) (string, string, string, int, error) {
	return "", "", "", 0, errors.New("not implemented")
}

func (s *intakeTrustStore) ApproveHardwareTrustApproval(context.Context, string, string) (string, string, string, int, *time.Time, string, string, string, *time.Time, error) {
	return "", "", "", 0, nil, "", "", "", nil, errors.New("not implemented")
}

func (s *intakeTrustStore) RevokeHardwareTrustApproval(context.Context, string, string, string, string) (string, int, bool, error) {
	return "", 0, false, errors.New("not implemented")
}

func (s *intakeTrustStore) ListWaitingTrustJobs(context.Context, int64, int) ([]onboarding.WaitingTrustJob, error) {
	return nil, nil
}

func (s *intakeTrustStore) ProviderHardwareTrustState(_ context.Context, providerID string, _ time.Time) (bool, bool, error) {
	if s.err != nil {
		return false, false, s.err
	}
	return s.held[providerID], s.active[providerID], nil
}

// SPEC-047 R009: the intake aggregate counts distinct providers per
// intake-resolved key from DISTINCT pairs, excludes sanctioned providers and
// (where trust is operated) providers without an active trust root at build
// time, suppresses below the fixed floor, and serves a materialized,
// nonce-carrying snapshot.
func TestModelAdmissionIntakeAggregate(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret"}
	s.admission = NewAdmissionManager(s.cfg.Admission, s.now)
	c := operatorClient{t: t, s: s}
	const intakePath = "/admin/model-admission/intake"

	// No snapshot yet: unavailable, never a partial count.
	if code, body := c.do(http.MethodGet, intakePath, "alice-secret", nil); code != http.StatusServiceUnavailable || errorCode(body) != "intake_unavailable" {
		t.Fatalf("no snapshot: code=%d body=%v", code, body)
	}

	// Three providers offer the row's primary hash (the intake key resolves
	// through the row whatever its tier), one of them twice from two
	// candidates; a fourth offers a hash that resolves to nothing.
	for _, p := range []string{"p1", "p2", "p3"} {
		f.registerSession(t, p, "s-"+p, "model-a", true)
		ev := f.offer(t, p, "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
		if ev.IntakeModelKey == "" || ev.IntakeModelKey != ev.CatalogModelKey {
			t.Fatalf("intake key must resolve for a row-hash offer: %+v", ev)
		}
	}
	f.offer(t, "p1", "b", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	f.registerSession(t, "p4", "s-p4", "model-a", true)
	unresolved := f.offer(t, "p4", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: strings.Repeat("f", 64)})
	if unresolved.IntakeModelKey != "" || unresolved.CatalogModelKey != "" {
		t.Fatalf("an unresolved offer must carry no intake key: %+v", unresolved)
	}
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
		t.Fatalf("build: %v", err)
	}
	code, body := c.do(http.MethodGet, intakePath, "alice-secret", nil)
	if code != http.StatusOK {
		t.Fatalf("code=%d body=%v", code, body)
	}
	for _, k := range []string{"schema", "nonce", "generated_at", "window_start", "window_end", "k_anonymity_min", "rows"} {
		if _, ok := body[k]; !ok {
			t.Fatalf("missing %q in %v", k, body)
		}
	}
	if len(body) != 7 || body["schema"] != modelAdmissionIntakeSchema || body["k_anonymity_min"] != float64(3) || len(body["nonce"].(string)) != 32 {
		t.Fatalf("frame = %v", body)
	}
	rows := body["rows"].([]any)
	if len(rows) != 1 {
		t.Fatalf("rows = %v, want one key", rows)
	}
	row := rows[0].(map[string]any)
	if row["distinct_provider_offer_count"] != float64(3) || row["suppressed"] != false || len(row) != 3 {
		t.Fatalf("row = %v, want 3 distinct providers (p1 counted once)", row)
	}
	key := row["catalog_model_key"].(string)
	for _, forbidden := range []string{"p1", "p2", "p3", "candidate", "served"} {
		if strings.Contains(strings.ToLower(key), forbidden) {
			t.Fatalf("row leaks %q", forbidden)
		}
	}
	// Two builds carry different nonces for identical rows.
	first := body["nonce"]
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, again := c.do(http.MethodGet, intakePath, "alice-secret", nil); again["nonce"] == first {
		t.Fatalf("nonce must be fresh per build")
	}

	// Auth and query rules.
	if code, body := c.do(http.MethodGet, intakePath, "", nil); code != http.StatusUnauthorized || errorCode(body) != "invalid_operator_token" {
		t.Fatalf("no bearer: code=%d body=%v", code, body)
	}
	if code, body := c.do(http.MethodGet, intakePath+"?window=30d", "alice-secret", nil); code != http.StatusBadRequest || errorCode(body) != "invalid_request" {
		t.Fatalf("query parameter: code=%d body=%v", code, body)
	}
	if code, body := c.do(http.MethodPost, intakePath, "alice-secret", map[string]any{}); code != http.StatusBadRequest || errorCode(body) != "invalid_request" {
		t.Fatalf("POST: code=%d body=%v", code, body)
	}

	// A route sanction (admission rejection) on p2 after its offer removes
	// it at the next build: 2 < 3 → suppressed row with a null count.
	s.admission.Reject("p2", "test")
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
		t.Fatalf("build: %v", err)
	}
	_, body = c.do(http.MethodGet, intakePath, "alice-secret", nil)
	row = body["rows"].([]any)[0].(map[string]any)
	if row["distinct_provider_offer_count"] != nil || row["suppressed"] != true {
		t.Fatalf("after sanction row = %v, want suppressed with null count", row)
	}
	s.admission = NewAdmissionManager(s.cfg.Admission, s.now)

	// With hardware trust operated, only providers holding an ACTIVE root
	// count: p3 held-and-revoked is sanctioned, p1 never-trusted is
	// ineligible; only p2 remains → suppressed. An unreadable trust source
	// aborts the build and keeps the previous snapshot.
	trust := &intakeTrustStore{held: map[string]bool{"p2": true, "p3": true}, active: map[string]bool{"p2": true}}
	s.hardwareTrustAdmin = trust
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
		t.Fatalf("build: %v", err)
	}
	_, body = c.do(http.MethodGet, intakePath, "alice-secret", nil)
	if rows := body["rows"].([]any); len(rows) != 1 || rows[0].(map[string]any)["suppressed"] != true {
		t.Fatalf("rows with trust operated = %v", rows)
	}
	trust.active["p1"], trust.active["p3"], trust.held["p1"] = true, true, true
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
		t.Fatalf("build: %v", err)
	}
	_, body = c.do(http.MethodGet, intakePath, "alice-secret", nil)
	if rows := body["rows"].([]any); rows[0].(map[string]any)["distinct_provider_offer_count"] != float64(3) {
		t.Fatalf("three active-trust providers should count: %v", rows)
	}
	trust.err = errors.New("trust store down")
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err == nil {
		t.Fatalf("an unreadable sanction source must abort the build")
	}
	if code, _ := c.do(http.MethodGet, intakePath, "alice-secret", nil); code != http.StatusOK {
		t.Fatalf("previous snapshot must be retained after a failed build: %d", code)
	}
	trust.err = nil
	// The offer-submission gate keeps its v0.1.5 scope: a trust-revoked
	// provider is not refused a new offer by it, an admission-rejected one is.
	if s.providerModelAdmissionSanctioned("p3") {
		t.Fatalf("offer gate must not widen to trust sanctions")
	}
	s.admission.Reject("p2", "test")
	if !s.providerModelAdmissionSanctioned("p2") {
		t.Fatalf("offer gate must refuse an admission-rejected provider")
	}

	// Staleness: two cadences after the build the snapshot is unavailable.
	s.now = func() time.Time { return f.now.Add(modelAdmissionIntakeStaleAfter + time.Minute) }
	if code, body := c.do(http.MethodGet, intakePath, "alice-secret", nil); code != http.StatusServiceUnavailable || errorCode(body) != "intake_unavailable" {
		t.Fatalf("stale snapshot: code=%d body=%v", code, body)
	}
}

func TestBuildModelAdmissionIntakeRowsCountsDistinctPairs(t *testing.T) {
	pairs := []ModelAdmissionIntakePair{
		{"a", "k1"}, {"a", "k1"}, {"b", "k1"}, {"i", "k1"},
		{"f", "k2"}, {"g", "k2"}, {"h", "k2"}, {"i", "k2"}, {"z", ""},
	}
	eligible := func(_ context.Context, id string) (bool, error) { return id != "i", nil }
	rows, err := BuildModelAdmissionIntakeRows(context.Background(), pairs, eligible, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].CatalogModelKey != "k1" || rows[1].CatalogModelKey != "k2" {
		t.Fatalf("rows = %+v", rows)
	}
	if !rows[0].Suppressed || rows[0].DistinctProviderOfferCount != nil {
		t.Fatalf("k1 has 2 eligible providers and must be suppressed: %+v", rows[0])
	}
	if rows[1].Suppressed || rows[1].DistinctProviderOfferCount == nil || *rows[1].DistinctProviderOfferCount != 3 {
		t.Fatalf("k2 has 3 eligible providers: %+v", rows[1])
	}
	if _, err := BuildModelAdmissionIntakeRows(context.Background(), pairs, func(context.Context, string) (bool, error) { return false, errors.New("down") }, 3); err == nil {
		t.Fatalf("an unreadable eligibility source must fail the build")
	}
}

func TestModelAdmissionIntakeOfferPairsWindowIsInclusiveAtSecondGranularity(t *testing.T) {
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	start := now.Add(-modelAdmissionIntakeWindow)
	for _, store := range []ModelAdmissionStore{NewMemoryModelAdmissionStore(), newSQLiteModelAdmissionStoreForTest(t)} {
		seq := 0
		ev := func(provider, key string, at time.Time, state string) ModelAdmissionEvent {
			seq++
			candidate := "byom_" + strings.Repeat("a", 52-len(fmt.Sprint(seq))) + fmt.Sprint(seq)
			id := fmt.Sprintf("%s-%d", provider, seq)
			return ModelAdmissionEvent{ProviderID: provider, CandidateID: candidate, ServedModelRef: "m", IntakeModelKey: key, State: state, NextState: state, RequestID: id, Nonce: id, CreatedAt: at}
		}
		for _, e := range []ModelAdmissionEvent{
			ev("a", "k1", now.Add(-time.Hour), modelAdmissionOfferSubmitted),
			ev("a", "k1", now.Add(-2*time.Hour), modelAdmissionOfferSubmitted),           // same pair twice: once
			ev("b", "k1", start.Add(500*time.Millisecond), modelAdmissionOfferSubmitted), // inside the first second of the window
			ev("c", "k1", start.Add(-time.Second), modelAdmissionOfferSubmitted),         // before the window
			ev("e", "", now.Add(-time.Minute), modelAdmissionOfferSubmitted),             // no intake key
			ev("i", "k2", now.Add(900*time.Millisecond), modelAdmissionOfferSubmitted),   // inside the last second: inclusive
			ev("j", "k2", now.Add(time.Second), modelAdmissionOfferSubmitted),            // after the window
		} {
			if _, _, err := store.AppendModelAdmissionOffer(context.Background(), e); err != nil {
				t.Fatalf("append: %v", err)
			}
		}
		// A withdrawal carrying an intake key is not an offer event: d's
		// offer names k9, its later withdrawal names k1, and only k9 counts.
		dOffer := ev("d", "k9", now.Add(-2*time.Minute), modelAdmissionOfferSubmitted)
		if _, _, err := store.AppendModelAdmissionOffer(context.Background(), dOffer); err != nil {
			t.Fatalf("append d offer: %v", err)
		}
		dWithdraw := ev("d", "k1", now.Add(-time.Minute), modelAdmissionWithdrawn)
		dWithdraw.CandidateID = dOffer.CandidateID
		if _, _, err := store.AppendModelAdmissionWithdrawal(context.Background(), dWithdraw); err != nil {
			t.Fatalf("append withdrawal: %v", err)
		}
		pairs, err := store.ModelAdmissionIntakeOfferPairs(context.Background(), start, now, 0)
		if err != nil {
			t.Fatal(err)
		}
		got := map[ModelAdmissionIntakePair]int{}
		for _, p := range pairs {
			got[p]++
		}
		want := map[ModelAdmissionIntakePair]int{{"a", "k1"}: 1, {"b", "k1"}: 1, {"d", "k9"}: 1, {"i", "k2"}: 1}
		// The ceiling is enforced at the store: a limit of 2 yields 2 pairs,
		// never the full set.
		if limited, err := store.ModelAdmissionIntakeOfferPairs(context.Background(), start, now, 2); err != nil || len(limited) != 2 {
			t.Fatalf("%T limit 2: pairs=%d err=%v, want 2", store, len(limited), err)
		}
		if len(got) != len(want) {
			t.Fatalf("%T pairs = %v, want %v", store, got, want)
		}
		for p, n := range want {
			if got[p] != n {
				t.Fatalf("%T pairs = %v, want %v", store, got, want)
			}
		}
	}
}

// newSQLiteModelAdmissionStoreForTest opens the coordinator SQLite store in a
// temp dir and returns the admission store over it.
func newSQLiteModelAdmissionStoreForTest(t *testing.T) ModelAdmissionStore {
	t.Helper()
	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatalf("sqlite admission store: %v", err)
	}
	return store
}
