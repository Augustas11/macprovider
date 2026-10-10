package ws

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

type fakePoolProvenSource struct {
	attempts []billing.PoolProvenAttempt
	entries  map[string]map[trustpool.AcceptedCoreKey][]poolmanifest.PoolModelEntry
	err      error
	limits   []int
}

func (f *fakePoolProvenSource) PoolProvenAttempts(_ context.Context, _, _ time.Time, limit int) ([]billing.PoolProvenAttempt, error) {
	f.limits = append(f.limits, limit)
	if f.err != nil {
		return nil, f.err
	}
	if len(f.attempts) > limit {
		return f.attempts[:limit], nil
	}
	return f.attempts, nil
}

func (f *fakePoolProvenSource) AcceptedPoolModelEntries(_ context.Context, poolID string) (map[trustpool.AcceptedCoreKey][]poolmanifest.PoolModelEntry, error) {
	return f.entries[poolID], nil
}

func poolProvenAttempt(provider, memberAccount string) billing.PoolProvenAttempt {
	return billing.PoolProvenAttempt{
		ProviderID: provider, PoolID: testPoolA, PoolModelID: poolModelGGUF, ManifestVersion: 1, ManifestCoreDigest: poolDigestV1,
		ArtifactHashAlgorithm: modelidentity.GGUFFileV1, ArtifactHash: poolGGUFHash, RuntimeSource: "llamacpp_loopback",
		PoolMemberAccountID: memberAccount, PoolOperatorAccountID: poolCreator,
	}
}

// R012 rows: suppression below k distinct owner accounts (never sessions or
// provider ids), licence agreement, and the newest current passing probe.
func TestBuildModelAdmissionPoolProvenRows(t *testing.T) {
	pair := poolProvenPair{modelidentity.GGUFFileV1, poolGGUFHash}
	attempt := func(owner, license string, attested bool) PoolProvenCountedAttempt {
		return PoolProvenCountedAttempt{ArtifactHashAlgorithm: pair.algorithm, ArtifactHash: pair.hash, OwnerAccountID: owner, LicenseID: license, PaidServingAttested: attested}
	}
	for _, tc := range []struct {
		name     string
		attempts []PoolProvenCountedAttempt
		suppress bool
		count    int
		distinct int
		license  string
	}{
		{"one owner", []PoolProvenCountedAttempt{attempt("a", "MIT", true), attempt("a", "MIT", true)}, true, 0, 0, "MIT"},
		{"two owners", []PoolProvenCountedAttempt{attempt("a", "MIT", true), attempt("b", "MIT", true)}, true, 0, 0, "MIT"},
		{"three owners", []PoolProvenCountedAttempt{attempt("a", "MIT", true), attempt("b", "MIT", true), attempt("c", "MIT", true), attempt("c", "MIT", true)}, false, 4, 3, "MIT"},
		{"licence disagreement", []PoolProvenCountedAttempt{attempt("a", "MIT", true), attempt("b", "Apache-2.0", true), attempt("c", "MIT", true)}, false, 3, 3, ""},
		{"not attested", []PoolProvenCountedAttempt{attempt("a", "MIT", true), attempt("b", "MIT", false), attempt("c", "MIT", true)}, false, 3, 3, ""},
		{"entry not found", []PoolProvenCountedAttempt{attempt("a", "", false), attempt("b", "MIT", true), attempt("c", "MIT", true)}, false, 3, 3, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rows := BuildModelAdmissionPoolProvenRows(tc.attempts, nil, 3)
			if len(rows) != 1 {
				t.Fatalf("rows = %+v", rows)
			}
			r := rows[0]
			if r.Suppressed != tc.suppress || (r.PaidRequestCount == nil) != tc.suppress || (r.DistinctProviderCount == nil) != tc.suppress {
				t.Fatalf("suppression = %+v", r)
			}
			if !tc.suppress && (*r.PaidRequestCount != tc.count || *r.DistinctProviderCount != tc.distinct) {
				t.Fatalf("counts = %d/%d", *r.PaidRequestCount, *r.DistinctProviderCount)
			}
			if (tc.license == "") != (r.LicenseID == nil) || (r.LicenseID != nil && *r.LicenseID != tc.license) {
				t.Fatalf("license = %v want %q", r.LicenseID, tc.license)
			}
			if r.ProbeEvidenceDigest != nil || r.ProbeEvaluatedAt != nil {
				t.Fatalf("probe fields without a record: %+v", r)
			}
		})
	}
	probe := StoredModelAdmissionProbeEvidence{Record: testProbeEvidence(ModelAdmissionProbeResultPass, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)), Digest: strings.Repeat("e", 64)}
	other := PoolProvenCountedAttempt{ArtifactHashAlgorithm: modelidentity.GGUFFileV1, ArtifactHash: strings.Repeat("1", 64), OwnerAccountID: "a"}
	rows := BuildModelAdmissionPoolProvenRows([]PoolProvenCountedAttempt{attempt("a", "MIT", true), other}, map[poolProvenPair]StoredModelAdmissionProbeEvidence{pair: probe}, 3)
	if len(rows) != 2 || rows[0].ArtifactHash != strings.Repeat("1", 64) || rows[1].ArtifactHash != poolGGUFHash {
		t.Fatalf("rows are not ordered by pair: %+v", rows)
	}
	if rows[1].ProbeEvidenceDigest == nil || *rows[1].ProbeEvidenceDigest != probe.Digest || *rows[1].ProbeEvaluatedAt != "2026-10-01T00:00:00Z" || rows[0].ProbeEvidenceDigest != nil {
		t.Fatalf("probe fields = %+v / %+v", rows[1], rows[0])
	}
}

func TestPoolProvenOwnerAccountResolution(t *testing.T) {
	f := newBindingFixture(t)
	source := wirePoolSource(f)
	snap := poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
	snap.Members["native-owned"], snap.Members["native-member"], snap.Members["native-unknown"] = true, true, true
	snap.CreatorOwnedMembers["native-owned"] = true
	snap.MemberOwnerAccounts = map[string]string{"native-member": "acct-member"}
	source.set(snap)
	wiring := f.server.poolModels.Load()
	native := func(provider string) billing.PoolProvenAttempt {
		a := poolProvenAttempt(provider, "")
		a.RuntimeSource, a.PoolOperatorAccountID = "", ""
		return a
	}
	for name, tc := range map[string]struct {
		attempt billing.PoolProvenAttempt
		want    string
		ok      bool
	}{
		"member account":          {poolProvenAttempt("p", "acct-x"), "acct-x", true},
		"creator-owned loopback":  {poolProvenAttempt("p", ""), poolCreator, true},
		"native creator-owned":    {native("native-owned"), poolCreator, true},
		"native recorded owner":   {native("native-member"), "acct-member", true},
		"native without an owner": {native("native-unknown"), "", false},
	} {
		got, ok := poolProvenOwnerAccount(tc.attempt, wiring)
		if got != tc.want || ok != tc.ok {
			t.Fatalf("%s: owner = %q ok=%v", name, got, ok)
		}
	}
	if _, ok := poolProvenOwnerAccount(native("native-owned"), nil); ok {
		t.Fatal("a native attempt resolved without a registry")
	}
}

func TestModelAdmissionPoolProvenEndpoint(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret"}
	s.admission = NewAdmissionManager(s.cfg.Admission, s.now)
	s.probeEvidence = s.modelAdmissions.(ModelAdmissionProbeEvidenceStore)
	wirePoolSource(f).set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
	entry := ggufPoolEntry()
	src := &fakePoolProvenSource{
		attempts: []billing.PoolProvenAttempt{
			poolProvenAttempt("p1", "acct-1"), poolProvenAttempt("p2", "acct-2"), poolProvenAttempt("p3", "acct-3"), poolProvenAttempt("p3b", "acct-3"),
		},
		entries: map[string]map[trustpool.AcceptedCoreKey][]poolmanifest.PoolModelEntry{
			testPoolA: {{ManifestVersion: 1, ManifestCoreDigest: poolDigestV1}: {entry}},
		},
	}
	s.poolProven = src
	c := operatorClient{t: t, s: s}
	const path = "/admin/model-admission/pool-proven"
	if code, body := c.do(http.MethodGet, path, "alice-secret", nil); code != http.StatusServiceUnavailable || errorCode(body) != "pool_proven_unavailable" {
		t.Fatalf("no snapshot: code=%d body=%v", code, body)
	}
	passing := newModelAdmissionProbeEvidence("p1", "c1", modelidentity.GGUFFileV1, poolGGUFHash, "llamacpp_loopback", ModelAdmissionProbeResultPass, f.now.Add(-time.Hour))
	digest, err := s.probeEvidence.AppendModelAdmissionProbeEvidence(context.Background(), passing)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.probeEvidence.AppendModelAdmissionProbeEvidence(context.Background(), newModelAdmissionProbeEvidence("p1", "c1", modelidentity.GGUFFileV1, poolGGUFHash, "llamacpp_loopback", ModelAdmissionProbeResultPass, f.now.Add(-31*24*time.Hour))); err != nil {
		t.Fatal(err)
	}
	if err := s.buildModelAdmissionPoolProvenSnapshot(context.Background()); err != nil {
		t.Fatalf("build: %v", err)
	}
	if src.limits[0] != modelAdmissionPoolProvenAttemptCeiling+1 {
		t.Fatalf("attempt read limit = %d", src.limits[0])
	}
	code, body := c.do(http.MethodGet, path, "alice-secret", nil)
	if code != http.StatusOK || len(body) != 7 || body["schema"] != modelAdmissionPoolProvenSchema || body["k_anonymity_min"] != float64(3) || len(body["nonce"].(string)) != 32 ||
		body["window_end"] != body["generated_at"] || body["window_start"] != f.now.Add(-30*24*time.Hour).Format(time.RFC3339) {
		t.Fatalf("frame code=%d body=%v", code, body)
	}
	rows := body["rows"].([]any)
	row := rows[0].(map[string]any)
	if len(rows) != 1 || len(row) != 8 || row["paid_request_count"] != float64(4) || row["distinct_provider_count"] != float64(3) ||
		row["suppressed"] != false || row["license_id"] != "Apache-2.0" || row["probe_evidence_digest"] != digest ||
		row["probe_evaluated_at"] != passing.EvaluatedAt || row["artifact_hash"] != poolGGUFHash {
		t.Fatalf("row = %v", row)
	}
	raw := strings.Join([]string{"p1", "p2", "acct-1", testPoolA, poolCreator, poolModelGGUF}, "|")
	for _, forbidden := range strings.Split(raw, "|") {
		for k, v := range row {
			if s, ok := v.(string); ok && strings.Contains(s, forbidden) {
				t.Fatalf("row field %s leaks %q", k, forbidden)
			}
		}
	}
	// Refusals: method, query, credential.
	if code, body := c.do(http.MethodPost, path, "alice-secret", nil); code != http.StatusBadRequest || errorCode(body) != "invalid_request" {
		t.Fatalf("POST: code=%d body=%v", code, body)
	}
	if code, body := c.do(http.MethodGet, path+"?schema=x", "alice-secret", nil); code != http.StatusBadRequest || errorCode(body) != "invalid_request" {
		t.Fatalf("query: code=%d body=%v", code, body)
	}
	if code, body := c.do(http.MethodGet, path, "", nil); code != http.StatusUnauthorized || errorCode(body) != "invalid_operator_token" {
		t.Fatalf("no bearer: code=%d body=%v", code, body)
	}
	// The ceiling and a source failure leave the previous snapshot.
	_, first := c.do(http.MethodGet, path, "alice-secret", nil)
	src.attempts = make([]billing.PoolProvenAttempt, modelAdmissionPoolProvenAttemptCeiling+1)
	if err := s.buildModelAdmissionPoolProvenSnapshot(context.Background()); !errors.Is(err, errModelAdmissionPoolProvenCeiling) {
		t.Fatalf("ceiling build err = %v", err)
	}
	src.attempts, src.err = nil, errors.New("ledger unavailable")
	if err := s.buildModelAdmissionPoolProvenSnapshot(context.Background()); err == nil {
		t.Fatal("a source failure built a snapshot")
	}
	if _, again := c.do(http.MethodGet, path, "alice-secret", nil); again["nonce"] != first["nonce"] {
		t.Fatal("a failed build replaced the snapshot")
	}
	// A snapshot older than two cadences is unavailable.
	later := f.now.Add(modelAdmissionIntakeStaleAfter + time.Second)
	s.now = func() time.Time { return later }
	if code, body := c.do(http.MethodGet, path, "alice-secret", nil); code != http.StatusServiceUnavailable || errorCode(body) != "pool_proven_unavailable" {
		t.Fatalf("stale: code=%d body=%v", code, body)
	}
}
