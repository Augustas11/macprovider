package ws

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/jcs"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-047-R011 (v0.2.9): the coordinator-owned known-answer evidence record.
// A bounded probe runs through the authenticated provider session against the
// exact artifact pair a pool entry names; its result is stored append-only as
// the closed `model_admission_probe_evidence.v1` object and linked from the
// pool bind/rebind event by digest. The record is identity smoke evidence,
// never proof of weights, and it is not part of the provider-signed offer.

const (
	ModelAdmissionProbeEvidenceSchema      = "model_admission_probe_evidence.v1"
	ModelAdmissionKnownAnswerProbePolicyID = "macprovider.known_answer_probe.v1"

	ModelAdmissionProbeResultPass  = "pass"
	ModelAdmissionProbeResultFail  = "fail"
	ModelAdmissionProbeResultError = "error"

	modelAdmissionKnownAnswerPrompt    = "What is 17 + 25? Reply with only the number."
	modelAdmissionKnownAnswerExpected  = "42"
	modelAdmissionKnownAnswerSeed      = 1880
	modelAdmissionKnownAnswerMaxTokens = 256

	// ModelAdmissionProbeEvidenceCurrentWindow bounds a "current" record.
	ModelAdmissionProbeEvidenceCurrentWindow = 30 * 24 * time.Hour
	// A pool candidate is re-probed once its newest record is this old, or,
	// when that record did not pass, after the retry age.
	modelAdmissionProbeRefreshAge      = 7 * 24 * time.Hour
	modelAdmissionProbeRetryAge        = time.Hour
	modelAdmissionProbeRefreshInterval = 10 * time.Minute
	modelAdmissionProbeRefreshMax      = 32
	modelAdmissionKnownAnswerTimeout   = 10 * time.Second
	modelAdmissionProbeEvidenceCeiling = 100_000
)

// ModelAdmissionProbeDecoding is the record's closed `decoding` object.
type ModelAdmissionProbeDecoding struct {
	Temperature int   `json:"temperature"`
	Seed        int64 `json:"seed"`
	MaxTokens   int   `json:"max_tokens"`
}

// ModelAdmissionProbeEvidence is the closed `model_admission_probe_evidence.v1`
// record. EvaluatedAt is the coordinator clock, second precision.
type ModelAdmissionProbeEvidence struct {
	Schema                string                      `json:"schema"`
	ProviderID            string                      `json:"provider_id"`
	CandidateID           string                      `json:"candidate_id"`
	ArtifactHashAlgorithm string                      `json:"artifact_hash_algorithm"`
	ArtifactHash          string                      `json:"artifact_hash"`
	RuntimeSource         string                      `json:"runtime_source"`
	ProbePolicyID         string                      `json:"probe_policy_id"`
	PromptSetSHA256       string                      `json:"prompt_set_sha256"`
	Decoding              ModelAdmissionProbeDecoding `json:"decoding"`
	ExpectedAnswerSHA256  string                      `json:"expected_answer_sha256"`
	Result                string                      `json:"result"`
	EvaluatedAt           string                      `json:"evaluated_at"`
}

// StoredModelAdmissionProbeEvidence is a record with its digest.
type StoredModelAdmissionProbeEvidence struct {
	Record ModelAdmissionProbeEvidence
	Digest string
}

// EvaluatedTime parses the record's evaluated_at.
func (r ModelAdmissionProbeEvidence) EvaluatedTime() time.Time {
	t, err := time.Parse(time.RFC3339, r.EvaluatedAt)
	if err != nil {
		return time.Time{}
	}
	return t.UTC()
}

// ModelAdmissionProbeEvidenceStore is the append-only evidence store. It is
// optional: a model admission store without it records no evidence and every
// pool binding links null.
type ModelAdmissionProbeEvidenceStore interface {
	AppendModelAdmissionProbeEvidence(context.Context, ModelAdmissionProbeEvidence) (string, error)
	// LatestModelAdmissionProbeEvidence is the newest record for one
	// provider, candidate, and exact pair evaluated at or after since.
	LatestModelAdmissionProbeEvidence(ctx context.Context, providerID, candidateID, algorithm, hash string, since time.Time) (StoredModelAdmissionProbeEvidence, bool, error)
	// PassingModelAdmissionProbeEvidenceSince lists passing records under
	// policyID evaluated at or after since, newest first, at most limit.
	PassingModelAdmissionProbeEvidenceSince(ctx context.Context, policyID string, since time.Time, limit int) ([]StoredModelAdmissionProbeEvidence, error)
}

func modelAdmissionKnownAnswerMessages() []map[string]string {
	return []map[string]string{{"role": "user", "content": modelAdmissionKnownAnswerPrompt}}
}

func sha256HexString(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// modelAdmissionKnownAnswerPromptSetSHA256 is SHA-256(JCS(messages)).
func modelAdmissionKnownAnswerPromptSetSHA256() string {
	canonical, err := jcs.CanonicalJSON([]any{map[string]any{"role": "user", "content": modelAdmissionKnownAnswerPrompt}})
	if err != nil {
		panic("ws: known-answer prompt set does not encode: " + err.Error())
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:])
}

// newModelAdmissionProbeEvidence builds the record for one probe outcome.
func newModelAdmissionProbeEvidence(providerID, candidateID, algorithm, hash, runtimeSource, result string, at time.Time) ModelAdmissionProbeEvidence {
	return ModelAdmissionProbeEvidence{
		Schema:                ModelAdmissionProbeEvidenceSchema,
		ProviderID:            providerID,
		CandidateID:           candidateID,
		ArtifactHashAlgorithm: algorithm,
		ArtifactHash:          strings.ToLower(hash),
		RuntimeSource:         modelAdmissionRuntimeClass(runtimeSource),
		ProbePolicyID:         ModelAdmissionKnownAnswerProbePolicyID,
		PromptSetSHA256:       modelAdmissionKnownAnswerPromptSetSHA256(),
		Decoding: ModelAdmissionProbeDecoding{
			Temperature: 0,
			Seed:        modelAdmissionKnownAnswerSeed,
			MaxTokens:   modelAdmissionKnownAnswerMaxTokens,
		},
		ExpectedAnswerSHA256: sha256HexString(modelAdmissionKnownAnswerExpected),
		Result:               result,
		EvaluatedAt:          at.UTC().Truncate(time.Second).Format(time.RFC3339),
	}
}

// validateModelAdmissionProbeEvidence checks the closed record grammar.
func validateModelAdmissionProbeEvidence(r ModelAdmissionProbeEvidence) error {
	switch {
	case r.Schema != ModelAdmissionProbeEvidenceSchema:
		return errors.New("probe evidence: schema")
	case strings.TrimSpace(r.ProviderID) == "" || len(r.ProviderID) > 256 || strings.TrimSpace(r.CandidateID) == "" || len(r.CandidateID) > 256:
		return errors.New("probe evidence: provider or candidate id")
	case strings.TrimSpace(r.ArtifactHashAlgorithm) == "" || !validModelAdmissionSHA256Hex(r.ArtifactHash):
		return errors.New("probe evidence: artifact pair")
	case strings.TrimSpace(r.RuntimeSource) == "" || strings.TrimSpace(r.ProbePolicyID) == "":
		return errors.New("probe evidence: runtime source or policy")
	case !validModelAdmissionSHA256Hex(r.PromptSetSHA256) || !validModelAdmissionSHA256Hex(r.ExpectedAnswerSHA256):
		return errors.New("probe evidence: digests")
	case r.Decoding.Temperature != 0 || r.Decoding.MaxTokens < 1:
		return errors.New("probe evidence: decoding")
	}
	switch r.Result {
	case ModelAdmissionProbeResultPass, ModelAdmissionProbeResultFail, ModelAdmissionProbeResultError:
	default:
		return errors.New("probe evidence: result")
	}
	if t, err := time.Parse(time.RFC3339, r.EvaluatedAt); err != nil || t.UTC().Format(time.RFC3339) != r.EvaluatedAt {
		return errors.New("probe evidence: evaluated_at")
	}
	return nil
}

// modelAdmissionProbeEvidenceCanonical returns JCS(record) and its SHA-256.
func modelAdmissionProbeEvidenceCanonical(r ModelAdmissionProbeEvidence) ([]byte, string, error) {
	if err := validateModelAdmissionProbeEvidence(r); err != nil {
		return nil, "", err
	}
	raw, err := json.Marshal(r)
	if err != nil {
		return nil, "", err
	}
	var generic map[string]any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return nil, "", err
	}
	canonical, err := jcs.CanonicalJSON(generic)
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(canonical)
	return canonical, hex.EncodeToString(sum[:]), nil
}

// ModelAdmissionProbeEvidenceDigest is SHA-256(JCS(record)), 64 lowercase hex.
func ModelAdmissionProbeEvidenceDigest(r ModelAdmissionProbeEvidence) (string, error) {
	_, digest, err := modelAdmissionProbeEvidenceCanonical(r)
	return digest, err
}

// decodeModelAdmissionProbeEvidence parses stored canonical bytes and
// re-derives the digest; any disagreement fails closed.
func decodeModelAdmissionProbeEvidence(canonical []byte, digest string) (StoredModelAdmissionProbeEvidence, error) {
	dec := json.NewDecoder(strings.NewReader(string(canonical)))
	dec.DisallowUnknownFields()
	var r ModelAdmissionProbeEvidence
	if err := dec.Decode(&r); err != nil {
		return StoredModelAdmissionProbeEvidence{}, fmt.Errorf("probe evidence decode: %w", err)
	}
	again, recomputed, err := modelAdmissionProbeEvidenceCanonical(r)
	if err != nil {
		return StoredModelAdmissionProbeEvidence{}, err
	}
	if recomputed != digest || string(again) != string(canonical) {
		return StoredModelAdmissionProbeEvidence{}, errors.New("probe evidence digest mismatch")
	}
	return StoredModelAdmissionProbeEvidence{Record: r, Digest: digest}, nil
}

// ---- memory store

type memoryProbeEvidenceRow struct {
	canonical []byte
	stored    StoredModelAdmissionProbeEvidence
}

func (s *memoryModelAdmissionStore) AppendModelAdmissionProbeEvidence(_ context.Context, r ModelAdmissionProbeEvidence) (string, error) {
	canonical, digest, err := modelAdmissionProbeEvidenceCanonical(r)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, row := range s.probeEvidence {
		if row.stored.Digest == digest {
			return digest, nil
		}
	}
	s.probeEvidence = append(s.probeEvidence, memoryProbeEvidenceRow{canonical: canonical, stored: StoredModelAdmissionProbeEvidence{Record: r, Digest: digest}})
	return digest, nil
}

func (s *memoryModelAdmissionStore) LatestModelAdmissionProbeEvidence(_ context.Context, providerID, candidateID, algorithm, hash string, since time.Time) (StoredModelAdmissionProbeEvidence, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	hash = strings.ToLower(hash)
	for i := len(s.probeEvidence) - 1; i >= 0; i-- {
		r := s.probeEvidence[i].stored
		if r.Record.ProviderID == providerID && r.Record.CandidateID == candidateID &&
			r.Record.ArtifactHashAlgorithm == algorithm && r.Record.ArtifactHash == hash &&
			!r.Record.EvaluatedTime().Before(since.UTC().Truncate(time.Second)) {
			return r, true, nil
		}
	}
	return StoredModelAdmissionProbeEvidence{}, false, nil
}

func (s *memoryModelAdmissionStore) PassingModelAdmissionProbeEvidenceSince(_ context.Context, policyID string, since time.Time, limit int) ([]StoredModelAdmissionProbeEvidence, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []StoredModelAdmissionProbeEvidence
	for i := len(s.probeEvidence) - 1; i >= 0 && len(out) < limit; i-- {
		r := s.probeEvidence[i].stored
		if r.Record.Result == ModelAdmissionProbeResultPass && r.Record.ProbePolicyID == policyID &&
			!r.Record.EvaluatedTime().Before(since.UTC().Truncate(time.Second)) {
			out = append(out, r)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Record.EvaluatedAt > out[j].Record.EvaluatedAt })
	return out, nil
}

// ---- SQLite store

func ensureSQLiteModelAdmissionProbeEvidenceTable(db *sql.DB) error {
	_, err := db.ExecContext(context.Background(), `
CREATE TABLE IF NOT EXISTS model_admission_probe_evidence (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    probe_evidence_digest TEXT NOT NULL UNIQUE CHECK(length(probe_evidence_digest) = 64 AND probe_evidence_digest NOT GLOB '*[^0-9a-f]*'),
    provider_id TEXT NOT NULL,
    candidate_id TEXT NOT NULL,
    artifact_hash_algorithm TEXT NOT NULL,
    artifact_hash TEXT NOT NULL,
    probe_policy_id TEXT NOT NULL,
    result TEXT NOT NULL CHECK(result IN ('pass','fail','error')),
    evaluated_at_utc TEXT NOT NULL,
    record_jcs TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS model_admission_probe_evidence_candidate
    ON model_admission_probe_evidence(provider_id, candidate_id, artifact_hash_algorithm, artifact_hash, evaluated_at_utc);
CREATE INDEX IF NOT EXISTS model_admission_probe_evidence_passing
    ON model_admission_probe_evidence(result, probe_policy_id, evaluated_at_utc);
CREATE TRIGGER IF NOT EXISTS model_admission_probe_evidence_no_update
BEFORE UPDATE ON model_admission_probe_evidence
BEGIN
    SELECT RAISE(ABORT, 'model admission probe evidence is append-only');
END;
CREATE TRIGGER IF NOT EXISTS model_admission_probe_evidence_no_delete
BEFORE DELETE ON model_admission_probe_evidence
BEGIN
    SELECT RAISE(ABORT, 'model admission probe evidence is append-only');
END;`)
	return err
}

func (s *SQLiteModelAdmissionStore) AppendModelAdmissionProbeEvidence(ctx context.Context, r ModelAdmissionProbeEvidence) (string, error) {
	canonical, digest, err := modelAdmissionProbeEvidenceCanonical(r)
	if err != nil {
		return "", err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO model_admission_probe_evidence (
    probe_evidence_digest, provider_id, candidate_id, artifact_hash_algorithm, artifact_hash,
    probe_policy_id, result, evaluated_at_utc, record_jcs
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(probe_evidence_digest) DO NOTHING`,
		digest, r.ProviderID, r.CandidateID, r.ArtifactHashAlgorithm, r.ArtifactHash,
		r.ProbePolicyID, r.Result, r.EvaluatedAt, string(canonical))
	if err != nil {
		return "", err
	}
	return digest, nil
}

func (s *SQLiteModelAdmissionStore) LatestModelAdmissionProbeEvidence(ctx context.Context, providerID, candidateID, algorithm, hash string, since time.Time) (StoredModelAdmissionProbeEvidence, bool, error) {
	var canonical, digest string
	err := s.db.QueryRowContext(ctx, `
SELECT record_jcs, probe_evidence_digest
  FROM model_admission_probe_evidence
 WHERE provider_id = ? AND candidate_id = ? AND artifact_hash_algorithm = ? AND artifact_hash = ?
   AND evaluated_at_utc >= ?
 ORDER BY evaluated_at_utc DESC, id DESC
 LIMIT 1`,
		providerID, candidateID, algorithm, strings.ToLower(hash), since.UTC().Truncate(time.Second).Format(time.RFC3339)).Scan(&canonical, &digest)
	if errors.Is(err, sql.ErrNoRows) {
		return StoredModelAdmissionProbeEvidence{}, false, nil
	}
	if err != nil {
		return StoredModelAdmissionProbeEvidence{}, false, err
	}
	stored, err := decodeModelAdmissionProbeEvidence([]byte(canonical), digest)
	if err != nil {
		return StoredModelAdmissionProbeEvidence{}, false, err
	}
	return stored, true, nil
}

func (s *SQLiteModelAdmissionStore) PassingModelAdmissionProbeEvidenceSince(ctx context.Context, policyID string, since time.Time, limit int) ([]StoredModelAdmissionProbeEvidence, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT record_jcs, probe_evidence_digest
  FROM model_admission_probe_evidence
 WHERE result = 'pass' AND probe_policy_id = ? AND evaluated_at_utc >= ?
 ORDER BY evaluated_at_utc DESC, id DESC
 LIMIT ?`, policyID, since.UTC().Truncate(time.Second).Format(time.RFC3339), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []StoredModelAdmissionProbeEvidence
	for rows.Next() {
		var canonical, digest string
		if err := rows.Scan(&canonical, &digest); err != nil {
			return nil, err
		}
		stored, err := decodeModelAdmissionProbeEvidence([]byte(canonical), digest)
		if err != nil {
			return nil, err
		}
		out = append(out, stored)
	}
	return out, rows.Err()
}

// ---- probe runner

// knownAnswerProbePair is the exact pair a pool candidate is probed for: a
// pool-scoped binding's recorded pair, or the offered pair of an unbound head
// that matches exactly one current pool entry.
func knownAnswerProbePair(wiring *poolModelWiring, providerID string, head ModelAdmissionEvent, classify func(algorithm, hash string) poolCatalogPairStatus) (string, string, bool) {
	if head.PoolScoped() {
		if head.State != "catalog_priced" {
			return "", "", false
		}
		return head.ExpectedCatalogModelHashAlgorithm, head.ExpectedCatalogModelHash, true
	}
	matches, _, ok := poolBindMatches(wiring, providerID, head, classify)
	if !ok || len(matches) != 1 {
		return "", "", false
	}
	return offeredPoolPair(head)
}

// knownAnswerSessionServes reports whether the live session serves the
// candidate's served model and exact pair under its runtime class.
func knownAnswerSessionServes(provider pool.Provider, head ModelAdmissionEvent, algorithm, hash string) bool {
	return modelAdmissionRuntimeClass(provider.RuntimeSource) == modelAdmissionRuntimeClass(head.RuntimeSource) &&
		provider.ModelHashAlgorithm == algorithm &&
		strings.ToLower(strings.TrimSpace(provider.ModelHash)) == hash &&
		strings.EqualFold(strings.TrimSpace(provider.ModelID), strings.TrimSpace(head.ServedModelRef))
}

// normalizeKnownAnswer strips a leading reasoning block and surrounding
// whitespace and a trailing period from the completion text.
func normalizeKnownAnswer(text string) string {
	text = strings.TrimSpace(text)
	if strings.HasPrefix(text, "<think>") {
		end := strings.Index(text, "</think>")
		if end < 0 {
			return ""
		}
		text = strings.TrimSpace(text[end+len("</think>"):])
	}
	return strings.TrimSpace(strings.TrimSuffix(text, "."))
}

// knownAnswerChunkText extracts completion text from one relay chunk: a
// whole non-streaming chat-completion body, or SSE `data:` frames.
func knownAnswerChunkText(data string) string {
	if text, ok := knownAnswerPayloadText([]byte(data)); ok {
		return text
	}
	var b strings.Builder
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		if text, ok := knownAnswerPayloadText([]byte(payload)); ok {
			b.WriteString(text)
		}
	}
	return b.String()
}

func knownAnswerPayloadText(raw []byte) (string, bool) {
	var resp struct {
		Choices []struct {
			Message struct {
				Content *string `json:"content"`
			} `json:"message"`
			Delta struct {
				Content *string `json:"content"`
			} `json:"delta"`
			Text *string `json:"text"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil || len(resp.Choices) == 0 {
		return "", false
	}
	var b strings.Builder
	for _, c := range resp.Choices[:1] {
		for _, p := range []*string{c.Message.Content, c.Delta.Content, c.Text} {
			if p != nil {
				b.WriteString(*p)
			}
		}
	}
	return b.String(), true
}

// runModelAdmissionKnownAnswerProbe dispatches the known-answer probe through
// the provider session and appends its evidence record. It never changes the
// candidate's admission state.
func (s *Server) runModelAdmissionKnownAnswerProbe(ctx context.Context, provider pool.Provider, head ModelAdmissionEvent, algorithm, hash string) (StoredModelAdmissionProbeEvidence, error) {
	store := s.probeEvidence
	if store == nil {
		return StoredModelAdmissionProbeEvidence{}, errors.New("probe evidence store unavailable")
	}
	if provider.ProviderID != head.ProviderID || !provider.IsWSTunneled() || !knownAnswerSessionServes(provider, head, algorithm, hash) {
		return StoredModelAdmissionProbeEvidence{}, errors.New("known-answer probe requires the session to serve the candidate's exact pair")
	}
	body, err := json.Marshal(map[string]any{
		"model":       head.ServedModelRef,
		"messages":    modelAdmissionKnownAnswerMessages(),
		"temperature": 0,
		"seed":        modelAdmissionKnownAnswerSeed,
		"max_tokens":  modelAdmissionKnownAnswerMaxTokens,
		"stream":      false,
	})
	if err != nil {
		return StoredModelAdmissionProbeEvidence{}, err
	}
	probeCtx, cancel := context.WithTimeout(ctx, modelAdmissionKnownAnswerTimeout)
	defer cancel()
	result := ModelAdmissionProbeResultError
	relay, err := s.DispatchInference(probeCtx, provider, "model-admission-known-answer-"+s.newUUID(), body, false)
	if err == nil {
		var text strings.Builder
		chunks := relay.Chunks
	wait:
		for {
			select {
			case chunk, ok := <-chunks:
				if !ok {
					chunks = nil
					continue
				}
				if text.Len() < 64*1024 {
					text.WriteString(knownAnswerChunkText(chunk.Data))
				}
			case end := <-relay.Done:
				if end.Status == "complete" {
					result = ModelAdmissionProbeResultFail
					if normalizeKnownAnswer(text.String()) == modelAdmissionKnownAnswerExpected {
						result = ModelAdmissionProbeResultPass
					}
				}
				break wait
			case <-relay.Errors:
				break wait
			case <-probeCtx.Done():
				break wait
			}
		}
	}
	record := newModelAdmissionProbeEvidence(head.ProviderID, head.CandidateID, algorithm, hash, head.RuntimeSource, result, s.now())
	appendCtx, appendCancel := context.WithTimeout(context.WithoutCancel(ctx), modelAdmissionRuntimeRevocationTimeout)
	defer appendCancel()
	digest, err := store.AppendModelAdmissionProbeEvidence(appendCtx, record)
	if err != nil {
		return StoredModelAdmissionProbeEvidence{}, err
	}
	s.log.Info().
		Str("event", "model_admission_probe_evidence").
		Str("provider_id", head.ProviderID).
		Str("candidate_id", head.CandidateID).
		Str("result", result).
		Str("probe_evidence_digest", digest).
		Msg("model admission known-answer probe recorded")
	return StoredModelAdmissionProbeEvidence{Record: record, Digest: digest}, nil
}

// maybeRunKnownAnswerProbeForOffer probes a freshly offered pool candidate
// before the R011 bind, so the bind event can link its record.
func (s *Server) maybeRunKnownAnswerProbeForOffer(ctx context.Context, head ModelAdmissionEvent) {
	wiring := s.poolModels.Load()
	if wiring == nil || s.probeEvidence == nil {
		return
	}
	algorithm, hash, ok := knownAnswerProbePair(wiring, head.ProviderID, head, s.classifyCatalogPair)
	if !ok {
		return
	}
	provider, ok := s.modelAdmissionSyntheticProbeProvider(head.ProviderID)
	if !ok || !knownAnswerSessionServes(provider, head, algorithm, hash) {
		return
	}
	if _, err := s.runModelAdmissionKnownAnswerProbe(ctx, provider, head, algorithm, hash); err != nil {
		s.log.Warn().Err(err).Str("provider_id", head.ProviderID).Str("candidate_id", head.CandidateID).Msg("model admission known-answer probe not recorded")
	}
}

// linkedProbeEvidenceDigest is the digest an R011 bind or rebind event links:
// the newest record for the provider, candidate, and exact pair evaluated in
// the trailing current window, or "" when none exists or the store is absent.
func (s *Server) linkedProbeEvidenceDigest(ctx context.Context, event ModelAdmissionEvent) string {
	if s.probeEvidence == nil {
		return ""
	}
	stored, ok, err := s.probeEvidence.LatestModelAdmissionProbeEvidence(ctx, event.ProviderID, event.CandidateID,
		event.ExpectedCatalogModelHashAlgorithm, event.ExpectedCatalogModelHash, s.now().Add(-ModelAdmissionProbeEvidenceCurrentWindow))
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", event.ProviderID).Str("candidate_id", event.CandidateID).Msg("probe evidence lookup failed; binding links null")
		return ""
	}
	if !ok {
		return ""
	}
	return stored.Digest
}

// knownAnswerProbeDue reports whether a candidate needs a fresh probe.
func knownAnswerProbeDue(latest StoredModelAdmissionProbeEvidence, found bool, now time.Time) bool {
	if !found {
		return true
	}
	age := now.Sub(latest.Record.EvaluatedTime())
	if latest.Record.Result != ModelAdmissionProbeResultPass {
		return age >= modelAdmissionProbeRetryAge
	}
	return age >= modelAdmissionProbeRefreshAge
}

// RunModelAdmissionProbeEvidenceRefresh keeps pool candidates' known-answer
// evidence current: every refresh interval it probes, one at a time and at
// most modelAdmissionProbeRefreshMax per pass, each pool candidate with a live
// session serving its exact pair whose newest record is missing or due.
func (s *Server) RunModelAdmissionProbeEvidenceRefresh(ctx context.Context) {
	ticker := time.NewTicker(modelAdmissionProbeRefreshInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		s.refreshModelAdmissionProbeEvidence(ctx)
	}
}

func (s *Server) refreshModelAdmissionProbeEvidence(ctx context.Context) {
	wiring := s.poolModels.Load()
	if wiring == nil || s.modelAdmissions == nil || s.probeEvidence == nil {
		return
	}
	heads, err := s.modelAdmissions.LatestModelAdmissionStatusesInStates(ctx, []string{
		modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced",
	})
	if err != nil {
		s.log.Warn().Err(err).Msg("probe evidence refresh: listing failed")
		return
	}
	probed := 0
	for _, head := range heads {
		if probed >= modelAdmissionProbeRefreshMax || ctx.Err() != nil {
			return
		}
		algorithm, hash, ok := knownAnswerProbePair(wiring, head.ProviderID, head, s.classifyCatalogPair)
		if !ok {
			continue
		}
		provider, ok := s.modelAdmissionSyntheticProbeProvider(head.ProviderID)
		if !ok || !knownAnswerSessionServes(provider, head, algorithm, hash) {
			continue
		}
		latest, found, err := s.probeEvidence.LatestModelAdmissionProbeEvidence(ctx, head.ProviderID, head.CandidateID, algorithm, hash, time.Time{})
		if err != nil || !knownAnswerProbeDue(latest, found, s.now()) {
			continue
		}
		probed++
		if _, err := s.runModelAdmissionKnownAnswerProbe(ctx, provider, head, algorithm, hash); err != nil {
			s.log.Warn().Err(err).Str("provider_id", head.ProviderID).Str("candidate_id", head.CandidateID).Msg("probe evidence refresh: probe not recorded")
		}
	}
}
