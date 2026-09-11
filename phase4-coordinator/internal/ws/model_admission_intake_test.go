package ws

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
)

// intakeTrustStore is a HardwareTrustAdminStore whose only live method is
// the SPEC-047 v0.1.6 trust-sanction read.
type intakeTrustStore struct {
	sanctioned map[string]bool
	err        error
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

func (s *intakeTrustStore) ProviderHardwareTrustSanctioned(_ context.Context, providerID string) (bool, error) {
	if s.err != nil {
		return false, s.err
	}
	return s.sanctioned[providerID], nil
}

// SPEC-047 v0.1.6: the intake aggregate counts distinct providers per
// catalog_matched key, excludes sanctioned providers at build time, and
// suppresses below the fixed floor; GET reads a materialized snapshot.
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

	// Three providers offer the catalog-matched row (same key), one of them
	// twice from two candidates; a fourth offers an unmatched hash.
	for _, p := range []string{"p1", "p2", "p3"} {
		f.registerSession(t, p, "s-"+p, "model-a", true)
		f.offer(t, p, "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	}
	f.offer(t, "p1", "b", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	f.registerSession(t, "p4", "s-p4", "model-a", true)
	unmatched := f.offer(t, "p4", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: strings.Repeat("f", 64)})
	if unmatched.CatalogModelKey != "" {
		t.Fatalf("unmatched offer must carry no catalog key: %+v", unmatched)
	}
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
		t.Fatalf("build: %v", err)
	}
	code, body := c.do(http.MethodGet, intakePath, "alice-secret", nil)
	if code != http.StatusOK {
		t.Fatalf("code=%d body=%v", code, body)
	}
	for _, k := range []string{"schema", "generated_at", "window_start", "window_end", "k_anonymity_min", "rows"} {
		if _, ok := body[k]; !ok {
			t.Fatalf("missing %q in %v", k, body)
		}
	}
	if len(body) != 6 || body["schema"] != modelAdmissionIntakeSchema || body["k_anonymity_min"] != float64(3) {
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

	// A trust sanction on p3 (root held, none active) counts the same way;
	// an unreadable trust source aborts the build and keeps the previous
	// snapshot.
	trust := &intakeTrustStore{sanctioned: map[string]bool{"p3": true}}
	s.hardwareTrustAdmin = trust
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
		t.Fatalf("build: %v", err)
	}
	_, body = c.do(http.MethodGet, intakePath, "alice-secret", nil)
	if rows := body["rows"].([]any); len(rows) != 1 || rows[0].(map[string]any)["suppressed"] != true {
		t.Fatalf("rows after trust sanction = %v", rows)
	}
	trust.err = errors.New("trust store down")
	if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err == nil {
		t.Fatalf("an unreadable sanction source must abort the build")
	}
	if code, _ := c.do(http.MethodGet, intakePath, "alice-secret", nil); code != http.StatusOK {
		t.Fatalf("previous snapshot must be retained after a failed build: %d", code)
	}
	// The offer path refuses the sanctioned provider through the same
	// predicate and fails closed when the source is unreadable.
	if !s.providerModelAdmissionSanctioned("p3") || !s.providerModelAdmissionSanctioned("p1") {
		t.Fatalf("offer path must refuse a sanctioned provider and fail closed on an unreadable source")
	}
	trust.err = nil
	if s.providerModelAdmissionSanctioned("p1") {
		t.Fatalf("p1 is not sanctioned")
	}

	// Staleness: two cadences after the build the snapshot is unavailable.
	s.now = func() time.Time { return f.now.Add(modelAdmissionIntakeStaleAfter + time.Minute) }
	if code, body := c.do(http.MethodGet, intakePath, "alice-secret", nil); code != http.StatusServiceUnavailable || errorCode(body) != "intake_unavailable" {
		t.Fatalf("stale snapshot: code=%d body=%v", code, body)
	}
}

func TestBuildModelAdmissionIntakeRowsWindowAndCounting(t *testing.T) {
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	start := now.Add(-modelAdmissionIntakeWindow)
	ev := func(provider, key string, at time.Time, state string) ModelAdmissionEvent {
		return ModelAdmissionEvent{ProviderID: provider, CandidateID: "c-" + provider + key, CatalogModelKey: key, State: state, CreatedAt: at}
	}
	events := []ModelAdmissionEvent{
		ev("a", "k1", now.Add(-time.Hour), modelAdmissionOfferSubmitted),
		ev("a", "k1", now.Add(-2*time.Hour), modelAdmissionOfferSubmitted),   // same provider twice: once
		ev("b", "k1", start, modelAdmissionOfferSubmitted),                   // window start is inclusive
		ev("c", "k1", start.Add(-time.Second), modelAdmissionOfferSubmitted), // before the window
		ev("d", "k1", now.Add(-time.Minute), "withdrawn"),                    // not an offer event
		ev("e", "", now.Add(-time.Minute), modelAdmissionOfferSubmitted),     // unmatched: no key
		ev("f", "k2", now.Add(-time.Minute), modelAdmissionOfferSubmitted),
		ev("g", "k2", now.Add(-time.Minute), modelAdmissionOfferSubmitted),
		ev("h", "k2", now.Add(-time.Minute), modelAdmissionOfferSubmitted),
		ev("i", "k2", now, modelAdmissionOfferSubmitted), // window end is inclusive
	}
	sanctioned := func(_ context.Context, id string) (bool, error) { return id == "i", nil }
	rows, err := BuildModelAdmissionIntakeRows(context.Background(), events, start, now, sanctioned, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].CatalogModelKey != "k1" || rows[1].CatalogModelKey != "k2" {
		t.Fatalf("rows = %+v", rows)
	}
	if !rows[0].Suppressed || rows[0].DistinctProviderOfferCount != nil {
		t.Fatalf("k1 has 2 providers (a, b) and must be suppressed: %+v", rows[0])
	}
	if rows[1].Suppressed || rows[1].DistinctProviderOfferCount == nil || *rows[1].DistinctProviderOfferCount != 3 {
		t.Fatalf("k2 has 3 unsanctioned providers (f, g, h): %+v", rows[1])
	}
	if _, err := BuildModelAdmissionIntakeRows(context.Background(), events, start, now, func(context.Context, string) (bool, error) { return false, errors.New("down") }, 3); err == nil {
		t.Fatalf("an unreadable sanction source must fail the build")
	}
}
