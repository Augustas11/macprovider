package ws

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/rs/zerolog"
)

func testProbeEvidence(result string, at time.Time) ModelAdmissionProbeEvidence {
	return newModelAdmissionProbeEvidence(poolProvider, "byom_"+strings.Repeat("p", 52), modelidentity.GGUFFileV1, poolGGUFHash, "llamacpp_loopback", result, at)
}

// SPEC-047-R011: the record is the closed v1 object and its digest is
// SHA-256(JCS(record)); a stored record whose bytes or digest disagree fails
// closed on read.
func TestModelAdmissionProbeEvidenceRecordDigest(t *testing.T) {
	at := time.Date(2026, 10, 1, 12, 0, 0, 500, time.UTC)
	record := testProbeEvidence(ModelAdmissionProbeResultPass, at)
	canonical, digest, err := modelAdmissionProbeEvidenceCanonical(record)
	if err != nil {
		t.Fatalf("canonical: %v", err)
	}
	want := `{"artifact_hash":"` + poolGGUFHash + `","artifact_hash_algorithm":"` + modelidentity.GGUFFileV1 +
		`","candidate_id":"byom_` + strings.Repeat("p", 52) + `","decoding":{"max_tokens":256,"seed":1880,"temperature":0},` +
		`"evaluated_at":"2026-10-01T12:00:00Z","expected_answer_sha256":"` + sha256HexString("42") +
		`","probe_policy_id":"macprovider.known_answer_probe.v1","prompt_set_sha256":"` + modelAdmissionKnownAnswerPromptSetSHA256() +
		`","provider_id":"` + poolProvider + `","result":"pass","runtime_source":"llamacpp_loopback","schema":"model_admission_probe_evidence.v1"}`
	if string(canonical) != want {
		t.Fatalf("canonical =\n%s\nwant\n%s", canonical, want)
	}
	sum := sha256.Sum256([]byte(want))
	if digest != hex.EncodeToString(sum[:]) {
		t.Fatalf("digest = %s", digest)
	}
	if _, err := decodeModelAdmissionProbeEvidence(canonical, strings.Repeat("0", 64)); err == nil {
		t.Fatal("a digest mismatch decoded")
	}
	if _, err := decodeModelAdmissionProbeEvidence([]byte(strings.Replace(want, `"result":"pass"`, `"extra":1,"result":"pass"`, 1)), digest); err == nil {
		t.Fatal("an unknown field decoded")
	}
	for name, mutate := range map[string]func(*ModelAdmissionProbeEvidence){
		"result":      func(r *ModelAdmissionProbeEvidence) { r.Result = "maybe" },
		"temperature": func(r *ModelAdmissionProbeEvidence) { r.Decoding.Temperature = 1 },
		"hash":        func(r *ModelAdmissionProbeEvidence) { r.ArtifactHash = "XYZ" },
		"schema":      func(r *ModelAdmissionProbeEvidence) { r.Schema = "v0" },
		"time":        func(r *ModelAdmissionProbeEvidence) { r.EvaluatedAt = "2026-10-01T12:00:00.5Z" },
		"policy":      func(r *ModelAdmissionProbeEvidence) { r.ProbePolicyID = "macprovider.known_answer_probe.v0" },
		"prompt set":  func(r *ModelAdmissionProbeEvidence) { r.PromptSetSHA256 = strings.Repeat("a", 64) },
		"expected":    func(r *ModelAdmissionProbeEvidence) { r.ExpectedAnswerSHA256 = strings.Repeat("a", 64) },
		"seed":        func(r *ModelAdmissionProbeEvidence) { r.Decoding.Seed = 7 },
		"max tokens":  func(r *ModelAdmissionProbeEvidence) { r.Decoding.MaxTokens = 4 },
	} {
		bad := record
		mutate(&bad)
		if _, err := ModelAdmissionProbeEvidenceDigest(bad); err == nil {
			t.Fatalf("%s: invalid record accepted", name)
		}
	}
}

func TestModelAdmissionProbeEvidenceStoresAreAppendOnly(t *testing.T) {
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "admission.db")))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	sqliteStore, err := NewSQLiteModelAdmissionStore(db)
	if err != nil {
		t.Fatalf("sqlite store: %v", err)
	}
	stores := map[string]ModelAdmissionProbeEvidenceStore{
		"memory": NewMemoryModelAdmissionStore().(ModelAdmissionProbeEvidenceStore),
		"sqlite": sqliteStore,
	}
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	for name, store := range stores {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			old := testProbeEvidence(ModelAdmissionProbeResultPass, base.Add(-40*24*time.Hour))
			failed := testProbeEvidence(ModelAdmissionProbeResultFail, base.Add(-2*time.Hour))
			passed := testProbeEvidence(ModelAdmissionProbeResultPass, base.Add(-time.Hour))
			var digests []string
			for _, r := range []ModelAdmissionProbeEvidence{old, failed, passed} {
				digest, err := store.AppendModelAdmissionProbeEvidence(ctx, r)
				if err != nil {
					t.Fatalf("append: %v", err)
				}
				digests = append(digests, digest)
			}
			// An earlier evaluation appended last never shadows the newest.
			if _, err := store.AppendModelAdmissionProbeEvidence(ctx, testProbeEvidence(ModelAdmissionProbeResultError, base.Add(-3*time.Hour))); err != nil {
				t.Fatal(err)
			}
			if again, err := store.AppendModelAdmissionProbeEvidence(ctx, passed); err != nil || again != digests[2] {
				t.Fatalf("idempotent append = %s, %v", again, err)
			}
			latest, ok, err := store.LatestModelAdmissionProbeEvidence(ctx, passed.ProviderID, passed.CandidateID, passed.ArtifactHashAlgorithm, passed.ArtifactHash, base.Add(-30*24*time.Hour))
			if err != nil || !ok || latest.Digest != digests[2] || latest.Record != passed {
				t.Fatalf("latest = %+v ok=%v err=%v", latest, ok, err)
			}
			if _, ok, _ := store.LatestModelAdmissionProbeEvidence(ctx, passed.ProviderID, "other", passed.ArtifactHashAlgorithm, passed.ArtifactHash, time.Time{}); ok {
				t.Fatal("another candidate's record matched")
			}
			passing, err := store.PassingModelAdmissionProbeEvidenceSince(ctx, ModelAdmissionKnownAnswerProbePolicyID, base.Add(-30*24*time.Hour), 10)
			if err != nil || len(passing) != 1 || passing[0].Digest != digests[2] {
				t.Fatalf("passing = %+v err=%v", passing, err)
			}
		})
	}
	if _, err := db.Exec(`UPDATE model_admission_probe_evidence SET result = 'pass'`); err == nil {
		t.Fatal("sqlite probe evidence accepted an update")
	}
	if _, err := db.Exec(`DELETE FROM model_admission_probe_evidence`); err == nil {
		t.Fatal("sqlite probe evidence accepted a delete")
	}
}

// The bind event links the newest current record for the candidate and pair
// through pool_binding.probe_evidence_digest (covered by the event id); a
// record outside the current window links null, and the provider-signed
// evaluation digest is untouched.
func TestPoolManifestBindLinksProbeEvidence(t *testing.T) {
	for _, tc := range []struct {
		name string
		age  time.Duration
		link bool
	}{
		{"current", time.Hour, true},
		{"stale", 31 * 24 * time.Hour, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newBindingFixture(t)
			f.server.probeEvidence = f.server.modelAdmissions.(ModelAdmissionProbeEvidenceStore)
			source := wirePoolSource(f)
			source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
			f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
			offer := f.offer(t, poolProvider, "p", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
			record := newModelAdmissionProbeEvidence(poolProvider, offer.CandidateID, modelidentity.GGUFFileV1, poolGGUFHash, "llamacpp_loopback", ModelAdmissionProbeResultPass, f.now.Add(-tc.age))
			digest, err := f.server.probeEvidence.AppendModelAdmissionProbeEvidence(context.Background(), record)
			if err != nil {
				t.Fatalf("append evidence: %v", err)
			}
			f.reevaluate(poolProvider)
			head := f.latest(t, poolProvider, offer.CandidateID)
			if head.ReasonCode != ModelAdmissionReasonPoolManifestBound {
				t.Fatalf("head = %+v", head)
			}
			want := ""
			if tc.link {
				want = digest
			}
			if head.PoolProbeEvidenceDigest != want || head.EvaluationDigestSHA256 != offer.EvaluationDigestSHA256 {
				t.Fatalf("linked digest = %q want %q (evaluation %s)", head.PoolProbeEvidenceDigest, want, head.EvaluationDigestSHA256)
			}
			binding := f.server.modelAdmissionStatusResponseFromEvent(head, false)["pool_binding"].(map[string]any)
			if tc.link && binding["probe_evidence_digest"] != digest {
				t.Fatalf("status probe_evidence_digest = %v", binding["probe_evidence_digest"])
			}
			if !tc.link && binding["probe_evidence_digest"] != nil {
				t.Fatalf("stale record linked: %v", binding["probe_evidence_digest"])
			}
			unlinked := head
			unlinked.PoolProbeEvidenceDigest = ""
			if tc.link && prepareModelAdmissionTransition(unlinked, head.PreviousState, head.Actor, head.State).CoordinatorEventID == head.CoordinatorEventID {
				t.Fatal("the event id does not cover probe_evidence_digest")
			}
		})
	}
}

func TestKnownAnswerProbeDueAndNormalization(t *testing.T) {
	now := time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)
	at := func(result string, age time.Duration) StoredModelAdmissionProbeEvidence {
		return StoredModelAdmissionProbeEvidence{Record: testProbeEvidence(result, now.Add(-age))}
	}
	for _, tc := range []struct {
		name   string
		latest StoredModelAdmissionProbeEvidence
		found  bool
		due    bool
	}{
		{"missing", StoredModelAdmissionProbeEvidence{}, false, true},
		{"fresh pass", at("pass", 6*24*time.Hour), true, false},
		{"old pass", at("pass", 7*24*time.Hour), true, true},
		{"recent fail", at("fail", 30*time.Minute), true, false},
		{"older error", at("error", 2*time.Hour), true, true},
	} {
		if got := knownAnswerProbeDue(tc.latest, tc.found, now); got != tc.due {
			t.Fatalf("%s: due = %v", tc.name, got)
		}
	}
	for text, want := range map[string]string{
		"42":                       "42",
		" 42.\n":                   "42",
		"<think>17+25</think>\n42": "42",
		"<think>never closed 42":   "",
		"The answer is 42.":        "The answer is 42",
		"<think></think>41":        "41",
	} {
		if got := normalizeKnownAnswer(text); got != want {
			t.Fatalf("normalize(%q) = %q want %q", text, got, want)
		}
	}
	if got := knownAnswerChunkText("data: {\"choices\":[{\"delta\":{\"content\":\"4\"}}]}\ndata: {\"choices\":[{\"delta\":{\"content\":\"2\"}}]}\ndata: [DONE]\n"); got != "42" {
		t.Fatalf("sse text = %q", got)
	}
}

// The probe runs through the provider wire session with deterministic
// decoding and records pass, fail, or error; it never changes admission state.
func TestRunModelAdmissionKnownAnswerProbeRecordsResult(t *testing.T) {
	for _, tc := range []struct {
		name   string
		answer string
		status string
		want   string
	}{
		{"pass", "42", "complete", ModelAdmissionProbeResultPass},
		{"reasoning pass", "<think>add</think>42", "complete", ModelAdmissionProbeResultPass},
		{"wrong answer", "41", "complete", ModelAdmissionProbeResultFail},
		{"provider error", "42", "error", ModelAdmissionProbeResultError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			serverConn, providerConn := net.Pipe()
			defer serverConn.Close()
			defer providerConn.Close()
			registry := pool.NewRegistry(nil)
			provider := &pool.Provider{
				ProviderID: poolProvider, AssignedID: "session-ka", ModelID: "creator-model",
				RuntimeSource: "llamacpp_loopback", ModelHash: poolGGUFHash, ModelHashAlgorithm: modelidentity.GGUFFileV1,
				Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady,
				SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1, LastActivityAt: time.Now().UTC(), LastHeartbeatAt: time.Now().UTC(),
			}
			registry.Register(provider, serverConn)
			store := NewMemoryModelAdmissionStore()
			server := NewServer(config.Default(), registry, zerolog.Nop(), WithModelAdmissionStore(store))
			server.newUUID = func() string { return "ka" }
			session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, provider.MaxConcurrency)
			server.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), session)
			go session.runWriter()
			head := ModelAdmissionEvent{ProviderID: poolProvider, CandidateID: "byom_" + strings.Repeat("k", 52), ServedModelRef: "creator-model",
				RuntimeSource: "llamacpp_loopback", State: "catalog_priced"}

			done := make(chan struct{})
			go func() {
				defer close(done)
				req := readModelAdmissionProbeRequestFrame(t, providerConn)
				for _, want := range []string{`"temperature":0`, `"seed":1880`, `"max_tokens":256`, `"model":"creator-model"`, modelAdmissionKnownAnswerPrompt} {
					if !strings.Contains(req.Body, want) {
						t.Errorf("probe body %s lacks %s", req.Body, want)
					}
				}
				server.handleInferenceChunk(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseChunk{
					Type: "inference_response_chunk", RequestID: req.RequestID, Seq: 0,
					Data: `{"choices":[{"message":{"content":` + string(must(json.Marshal(tc.answer))) + `}}]}`,
				}))
				server.handleInferenceEnd(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseEnd{
					Type: "inference_response_end", RequestID: req.RequestID, Status: tc.status, ChunksSent: 1,
				}))
			}()
			stored, err := server.runModelAdmissionKnownAnswerProbe(context.Background(), *provider, head, modelidentity.GGUFFileV1, poolGGUFHash)
			<-done
			if err != nil {
				t.Fatalf("probe: %v", err)
			}
			if stored.Record.Result != tc.want {
				t.Fatalf("result = %s want %s", stored.Record.Result, tc.want)
			}
			latest, ok, err := server.probeEvidence.LatestModelAdmissionProbeEvidence(context.Background(), poolProvider, head.CandidateID, modelidentity.GGUFFileV1, poolGGUFHash, time.Time{})
			if err != nil || !ok || latest.Digest != stored.Digest {
				t.Fatalf("stored = %+v ok=%v err=%v", latest, ok, err)
			}
		})
	}
}

func TestRunModelAdmissionKnownAnswerProbeRequiresExactPair(t *testing.T) {
	store := NewMemoryModelAdmissionStore()
	server := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop(), WithModelAdmissionStore(store))
	provider := pool.Provider{ProviderID: poolProvider, ModelID: "creator-model", RuntimeSource: "llamacpp_loopback",
		ModelHash: strings.Repeat("7", 64), ModelHashAlgorithm: modelidentity.GGUFFileV1, InferencePath: pool.InferencePathWSTunneled}
	head := ModelAdmissionEvent{ProviderID: poolProvider, CandidateID: "c", ServedModelRef: "creator-model", RuntimeSource: "llamacpp_loopback"}
	if _, err := server.runModelAdmissionKnownAnswerProbe(context.Background(), provider, head, modelidentity.GGUFFileV1, poolGGUFHash); err == nil {
		t.Fatal("a session serving another pair was probed")
	}
}

func must(raw []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return raw
}

// Probe before bind: while an offer-time probe is in flight the binding
// evaluation leaves the candidate unbound; once it clears, the bind links the
// record the probe wrote.
func TestPoolManifestBindWaitsForInFlightOfferProbe(t *testing.T) {
	f := newBindingFixture(t)
	f.server.probeEvidence = f.server.modelAdmissions.(ModelAdmissionProbeEvidenceStore)
	source := wirePoolSource(f)
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	candidate := "byom_" + strings.Repeat("p", 52)
	release := f.server.holdKnownAnswerProbe(poolProvider, candidate)
	// An overlapping submission's release never clears this handler's hold.
	other := f.server.holdKnownAnswerProbe(poolProvider, candidate)
	other()
	other()
	offer := f.offer(t, poolProvider, "p", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); head.PoolScoped() {
		t.Fatalf("bound while the offer probe was in flight: %+v", head)
	}
	record := newModelAdmissionProbeEvidence(poolProvider, offer.CandidateID, modelidentity.GGUFFileV1, poolGGUFHash, "llamacpp_loopback", ModelAdmissionProbeResultPass, f.now)
	digest, err := f.server.probeEvidence.AppendModelAdmissionProbeEvidence(context.Background(), record)
	if err != nil {
		t.Fatal(err)
	}
	release()
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); !head.PoolScoped() || head.PoolProbeEvidenceDigest != digest {
		t.Fatalf("bind after the probe = %+v", head)
	}
}
