package hardwareverify

import (
	"context"
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

func TestEvaluateRejectsEachRemainingGate(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	other := strings.Repeat("a", 64)
	tests := []struct {
		name   string
		reason string
		mutate func(*Job, *Evidence)
	}{
		{"blank provider", "missing_provider_id", func(j *Job, _ *Evidence) { j.ProviderID = "  " }},
		{"job too old", "stale_job", func(j *Job, _ *Evidence) { j.GeneratedAt = now.Add(-maxEvidenceAge - time.Second) }},
		{"job in future", "stale_job", func(j *Job, _ *Evidence) { j.GeneratedAt = now.Add(futureSkew + time.Second) }},
		{"memory low", "memory_out_of_range", func(j *Job, _ *Evidence) { j.MemoryGB = 7 }},
		{"memory high", "memory_out_of_range", func(j *Job, _ *Evidence) { j.MemoryGB = 4097 }},
		{"no evidence", "missing_evidence", func(j *Job, _ *Evidence) { j.Evidence = nil }},
		{"schema", "schema_version_mismatch", func(_ *Job, e *Evidence) { e.SchemaVersion = "old" }},
		{"protocol", "probe_protocol_mismatch", func(_ *Job, e *Evidence) { e.ProbeProtocol = "old" }},
		{"bad evidence time", "invalid_evidence_generated_at", func(_ *Job, e *Evidence) { e.GeneratedAt = "yesterday" }},
		{"chip", "chip_mismatch", func(_ *Job, e *Evidence) { e.Hardware.Chip = "Apple M1" }},
		{"memory", "memory_mismatch", func(_ *Job, e *Evidence) { e.Hardware.MemoryGB = 64 }},
		{"tier", "bandwidth_tier_mismatch", func(_ *Job, e *Evidence) { e.Hardware.BandwidthTier = "S" }},
		{"os", "os_version_mismatch", func(_ *Job, e *Evidence) { e.Hardware.OSVersion = "14.0" }},
		{"identity hash", "invalid_hardware_identity_hash", func(_ *Job, e *Evidence) { e.Hardware.HardwareIdentityHash = "XYZ" }},
		{"exe hash", "invalid_executable_sha256", func(_ *Job, e *Evidence) { e.Hardware.ExecutableSHA256 = strings.ToUpper(other) }},
		{"catalog hash", "invalid_candidate_catalog_sha256", func(_ *Job, e *Evidence) { e.CandidateCatalogSHA256 = "" }},
		{"no benchmarks", "missing_benchmarks", func(_ *Job, e *Evidence) { e.Benchmarks = nil }},
		{"no model key", "missing_benchmark_model_binding", func(_ *Job, e *Evidence) { e.Benchmarks[0].ModelKey = " " }},
		{"no model id", "missing_benchmark_model_binding", func(_ *Job, e *Evidence) { e.Benchmarks[0].ModelID = "" }},
		{"duplicate key", "duplicate_benchmark_model_key", func(_ *Job, e *Evidence) { e.Benchmarks = append(e.Benchmarks, e.Benchmarks[0]) }},
		{"row identity", "invalid_benchmark_candidate_row_identity", func(_ *Job, e *Evidence) { e.Benchmarks[0].CandidateRowIdentity = "short" }},
		{"bench time", "invalid_benchmark_generated_at", func(_ *Job, e *Evidence) { e.Benchmarks[0].GeneratedAt = "" }},
		{"bench future", "stale_benchmark", func(_ *Job, e *Evidence) {
			e.Benchmarks[0].GeneratedAt = now.Add(time.Hour).Format(time.RFC3339)
		}},
		{"zero tps", "invalid_benchmark_tps", func(_ *Job, e *Evidence) { e.Benchmarks[0].SustainedTPS = 0 }},
		{"negative tps", "invalid_benchmark_tps", func(_ *Job, e *Evidence) { e.Benchmarks[0].SustainedTPS = -1 }},
		{"zero ttft", "invalid_benchmark_ttft", func(_ *Job, e *Evidence) { e.Benchmarks[0].TTFTMS = 0 }},
		{"blank chip normalized", "chip_mismatch", func(j *Job, _ *Evidence) { j.ChipNormalized = "" }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			job := validJob(t, now, "Apple M5", "C")
			var ev Evidence
			if err := json.Unmarshal(job.Evidence, &ev); err != nil {
				t.Fatal(err)
			}
			tc.mutate(&job, &ev)
			if tc.reason != "missing_evidence" {
				job.Evidence = mustEvidenceJSON(t, ev)
			}
			d := evaluateAt(job, now)
			if d.Verified || d.Reason != tc.reason {
				t.Fatalf("decision = %+v, want reason %q", d, tc.reason)
			}
		})
	}
}

func TestEvaluateRejectsMalformedEvidenceJSON(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	job := validJob(t, now, "Apple M5", "C")
	job.Evidence = []byte(`{not json`)
	if d := evaluateAt(job, now); d.Verified || d.Reason != "invalid_evidence_json" {
		t.Fatalf("decision = %+v", d)
	}
}

func TestEvaluateRejectsStaleEvidenceTimestamp(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	job := validJob(t, now, "Apple M5", "C")
	var ev Evidence
	if err := json.Unmarshal(job.Evidence, &ev); err != nil {
		t.Fatal(err)
	}
	// Job and evidence agree but sit just past the allowed skew window.
	future := now.Add(futureSkew + time.Minute)
	job.GeneratedAt = now // passes the job gate
	ev.GeneratedAt = future.Format(time.RFC3339)
	job.Evidence = mustEvidenceJSON(t, ev)
	if d := evaluateAt(job, now); d.Reason != "evidence_generated_at_mismatch" {
		t.Fatalf("decision = %+v", d)
	}
}

func TestEvaluateChipAndBandwidthComparisonsAreNormalized(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	job := validJob(t, now, "Apple M5", "C")
	var ev Evidence
	if err := json.Unmarshal(job.Evidence, &ev); err != nil {
		t.Fatal(err)
	}
	ev.Hardware.Chip = "  APPLE   m5 "
	ev.Hardware.BandwidthTier = " c "
	ev.Hardware.OSVersion = " 15.5 "
	job.Evidence = mustEvidenceJSON(t, ev)
	if d := evaluateAt(job, now); !d.Verified {
		t.Fatalf("decision = %+v", d)
	}
}

func TestHardwareVerifyHelpers(t *testing.T) {
	if got := normalizeChip("  Apple\t M4   Pro "); got != "apple m4 pro" {
		t.Fatalf("normalizeChip = %q", got)
	}
	if !isLowerSHA256(strings.Repeat("0f9a", 16)) {
		t.Fatal("valid lowercase sha rejected")
	}
	for _, bad := range []string{"", strings.Repeat("a", 63), strings.Repeat("a", 65), strings.Repeat("A", 64), strings.Repeat("g", 64)} {
		if isLowerSHA256(bad) {
			t.Fatalf("isLowerSHA256(%q) = true", bad)
		}
	}
	if hasPositiveBenchmark(nil) {
		t.Fatal("empty list has no positive benchmark")
	}
	if hasPositiveBenchmark([]Benchmark{{SustainedTPS: math.NaN()}, {SustainedTPS: math.Inf(1)}, {SustainedTPS: -2}}) {
		t.Fatal("NaN/Inf/negative must not count as positive")
	}
	if !hasPositiveBenchmark([]Benchmark{{SustainedTPS: 0}, {SustainedTPS: 1}}) {
		t.Fatal("positive benchmark not found")
	}
	if d := reject("x"); d.Verified || d.Reason != "x" {
		t.Fatalf("reject = %+v", d)
	}
}

func TestOpenValidatesDSNWithoutLeakingIt(t *testing.T) {
	if _, err := Open("   "); err == nil || !strings.Contains(err.Error(), "dsn is required") {
		t.Fatalf("blank dsn err = %v", err)
	}
	secret := "postgres://user:s3cretpw@host:notaport/db"
	_, err := Open(secret)
	if err == nil {
		t.Fatal("malformed dsn accepted")
	}
	if strings.Contains(err.Error(), "s3cretpw") || !strings.Contains(err.Error(), "redacted") {
		t.Fatalf("error leaks or lacks redaction: %v", err)
	}
	s, err := Open("postgres://u:p@127.0.0.1:1/db?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestNilStoreRefusesOperations(t *testing.T) {
	var s *Store
	if err := s.Close(); err != nil {
		t.Fatalf("nil Close = %v", err)
	}
	if err := s.Smoke(context.Background()); err == nil {
		t.Fatal("nil Smoke must error")
	}
	if _, err := s.ProcessPending(context.Background(), 1); err == nil {
		t.Fatal("nil ProcessPending must error")
	}
	empty := &Store{}
	if err := empty.Smoke(context.Background()); err == nil {
		t.Fatal("nil-db Smoke must error")
	}
	if _, err := empty.ProcessPending(context.Background(), 0); err == nil {
		t.Fatal("nil-db ProcessPending must error")
	}
}
