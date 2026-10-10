package ws

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-047-R012 — GET /admin/model-admission/pool-proven: the SPEC-023-R026
// pool-proven intake source. A materialized snapshot, rebuilt on the R009
// cadence, of settled paid pool-manifest attempts per exact artifact pair in
// the trailing 30 days: paid request count and distinct owner accounts
// (suppressed below k), the agreed licence, and the newest current passing
// known-answer record. Aggregated only: no pool, provider, creator, buyer,
// request, or wallet identity.

const (
	modelAdmissionPoolProvenSchema         = "model_admission_pool_proven.v1"
	modelAdmissionPoolProvenAttemptCeiling = 100_000
)

var (
	_ PoolProvenSource                 = (*SQLiteModelAdmissionStore)(nil)
	_ ModelAdmissionProbeEvidenceStore = (*SQLiteModelAdmissionStore)(nil)
)

var errModelAdmissionPoolProvenCeiling = errors.New("model admission pool-proven: counted-attempt ceiling exceeded")

// PoolProvenSource reads the ledger attempts and the accepted pool cores the
// aggregate is built from. The coordinator's SQLite admission store shares the
// ledger and trust-pool database and implements it.
type PoolProvenSource interface {
	PoolProvenAttempts(ctx context.Context, since, until time.Time, limit int) ([]billing.PoolProvenAttempt, error)
	AcceptedPoolModelEntries(ctx context.Context, poolID string) (map[trustpool.AcceptedCoreKey][]poolmanifest.PoolModelEntry, error)
}

// PoolProvenAttempts implements PoolProvenSource on the shared database.
func (s *SQLiteModelAdmissionStore) PoolProvenAttempts(ctx context.Context, since, until time.Time, limit int) ([]billing.PoolProvenAttempt, error) {
	return billing.QueryPoolProvenAttempts(ctx, s.db, since, until, limit)
}

// AcceptedPoolModelEntries implements PoolProvenSource on the shared database.
func (s *SQLiteModelAdmissionStore) AcceptedPoolModelEntries(ctx context.Context, poolID string) (map[trustpool.AcceptedCoreKey][]poolmanifest.PoolModelEntry, error) {
	return trustpool.AcceptedPoolModelEntries(ctx, s.db, poolID)
}

// ModelAdmissionPoolProvenRow is one closed `rows` element.
type ModelAdmissionPoolProvenRow struct {
	ArtifactHashAlgorithm string  `json:"artifact_hash_algorithm"`
	ArtifactHash          string  `json:"artifact_hash"`
	PaidRequestCount      *int    `json:"paid_request_count"`
	DistinctProviderCount *int    `json:"distinct_provider_count"`
	Suppressed            bool    `json:"suppressed"`
	LicenseID             *string `json:"license_id"`
	ProbeEvidenceDigest   *string `json:"probe_evidence_digest"`
	ProbeEvaluatedAt      *string `json:"probe_evaluated_at"`
}

// PoolProvenCountedAttempt is one counted attempt with its resolved owner
// account and the licence its accepted entry named ("" with attested false
// when the entry could not be found).
type PoolProvenCountedAttempt struct {
	ArtifactHashAlgorithm string
	ArtifactHash          string
	OwnerAccountID        string
	LicenseID             string
	PaidServingAttested   bool
}

type poolProvenPair struct{ algorithm, hash string }

// BuildModelAdmissionPoolProvenRows applies the R012 counting, suppression,
// licence-agreement, and probe-currency rules. probes maps a pair to its
// newest current passing record. Rows are ordered by algorithm then hash.
func BuildModelAdmissionPoolProvenRows(attempts []PoolProvenCountedAttempt, probes map[poolProvenPair]StoredModelAdmissionProbeEvidence, k int) []ModelAdmissionPoolProvenRow {
	type agg struct {
		count    int
		owners   map[string]struct{}
		license  string
		agreeing bool
	}
	pairs := map[poolProvenPair]*agg{}
	for _, a := range attempts {
		key := poolProvenPair{a.ArtifactHashAlgorithm, a.ArtifactHash}
		g := pairs[key]
		if g == nil {
			g = &agg{owners: map[string]struct{}{}, license: a.LicenseID, agreeing: true}
			pairs[key] = g
		}
		g.count++
		g.owners[a.OwnerAccountID] = struct{}{}
		if !a.PaidServingAttested || a.LicenseID == "" || a.LicenseID != g.license {
			g.agreeing = false
		}
	}
	keys := make([]poolProvenPair, 0, len(pairs))
	for key := range pairs {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].algorithm != keys[j].algorithm {
			return keys[i].algorithm < keys[j].algorithm
		}
		return keys[i].hash < keys[j].hash
	})
	rows := make([]ModelAdmissionPoolProvenRow, 0, len(keys))
	for _, key := range keys {
		g := pairs[key]
		row := ModelAdmissionPoolProvenRow{ArtifactHashAlgorithm: key.algorithm, ArtifactHash: key.hash}
		if owners := len(g.owners); owners < k {
			row.Suppressed = true
		} else {
			count, distinct := g.count, owners
			row.PaidRequestCount, row.DistinctProviderCount = &count, &distinct
		}
		if g.agreeing {
			license := g.license
			row.LicenseID = &license
		}
		if probe, ok := probes[key]; ok {
			digest, at := probe.Digest, probe.Record.EvaluatedAt
			row.ProbeEvidenceDigest, row.ProbeEvaluatedAt = &digest, &at
		}
		rows = append(rows, row)
	}
	return rows
}

// poolProvenOwnerAccount resolves an attempt's SPEC-003 owner account: the
// snapshot's member account, else for an external runtime the verified
// creator account the snapshot recorded, else (native) the pool creator when
// the provider is creator-owned or its recorded owner account in the current
// registry view. An unresolved attempt is not counted.
func poolProvenOwnerAccount(a billing.PoolProvenAttempt, wiring *poolModelWiring) (string, bool) {
	if a.PoolMemberAccountID != "" {
		return a.PoolMemberAccountID, true
	}
	if a.RuntimeSource != "" {
		return a.PoolOperatorAccountID, a.PoolOperatorAccountID != ""
	}
	if wiring == nil || wiring.source == nil {
		return "", false
	}
	view := wiring.source.Snapshot(a.PoolID)
	if view.CreatorAccountID != "" && view.CreatorOwnedMembers[a.ProviderID] {
		return view.CreatorAccountID, true
	}
	owner := view.MemberOwnerAccounts[a.ProviderID]
	return owner, owner != ""
}

type modelAdmissionPoolProvenSnapshot struct {
	generatedAt time.Time
	body        []byte
}

// modelAdmissionPoolProvenState is embedded in Server.
type modelAdmissionPoolProvenState struct {
	poolProven            PoolProvenSource
	modelAdmissionPPMu    sync.RWMutex
	modelAdmissionPPSnap  *modelAdmissionPoolProvenSnapshot
	modelAdmissionPPBuild sync.Mutex
}

// buildModelAdmissionPoolProvenSnapshot materializes the frame as one bounded
// job under the R009 limits: a query timeout, the counted-attempt ceiling,
// every source readable, otherwise the previous snapshot stays in place.
func (s *Server) buildModelAdmissionPoolProvenSnapshot(ctx context.Context) error {
	if s.poolProven == nil {
		return errors.New("pool-proven source unavailable")
	}
	if s.probeEvidence == nil {
		return errors.New("probe evidence store unavailable")
	}
	s.modelAdmissionPPBuild.Lock()
	defer s.modelAdmissionPPBuild.Unlock()
	ctx, cancel := context.WithTimeout(ctx, modelAdmissionIntakeBuildTimeout)
	defer cancel()
	generatedAt := s.now().UTC().Truncate(time.Second)
	windowStart := generatedAt.Add(-modelAdmissionIntakeWindow)
	attempts, err := s.poolProven.PoolProvenAttempts(ctx, windowStart, generatedAt, modelAdmissionPoolProvenAttemptCeiling+1)
	if err != nil {
		return fmt.Errorf("attempts: %w", err)
	}
	if len(attempts) > modelAdmissionPoolProvenAttemptCeiling {
		return errModelAdmissionPoolProvenCeiling
	}
	wiring := s.poolModels.Load()
	entriesByPool := map[string]map[trustpool.AcceptedCoreKey][]poolmanifest.PoolModelEntry{}
	counted := make([]PoolProvenCountedAttempt, 0, len(attempts))
	for _, a := range attempts {
		owner, ok := poolProvenOwnerAccount(a, wiring)
		if !ok || !validModelAdmissionSHA256Hex(a.ArtifactHash) || a.ArtifactHashAlgorithm == "" {
			continue
		}
		cores, seen := entriesByPool[a.PoolID]
		if !seen {
			cores, err = s.poolProven.AcceptedPoolModelEntries(ctx, a.PoolID)
			if err != nil {
				return fmt.Errorf("accepted entries: %w", err)
			}
			entriesByPool[a.PoolID] = cores
		}
		c := PoolProvenCountedAttempt{ArtifactHashAlgorithm: a.ArtifactHashAlgorithm, ArtifactHash: a.ArtifactHash, OwnerAccountID: owner}
		for _, entry := range cores[trustpool.AcceptedCoreKey{ManifestVersion: a.ManifestVersion, ManifestCoreDigest: a.ManifestCoreDigest}] {
			if entry.PoolModelID == a.PoolModelID && entry.ArtifactHashAlgorithm == a.ArtifactHashAlgorithm && entry.ArtifactHash == a.ArtifactHash {
				c.LicenseID, c.PaidServingAttested = entry.License, entry.PaidServingAttested
				break
			}
		}
		counted = append(counted, c)
	}
	passing, err := s.probeEvidence.PassingModelAdmissionProbeEvidenceSince(ctx, ModelAdmissionKnownAnswerProbePolicyID, generatedAt.Add(-ModelAdmissionProbeEvidenceCurrentWindow), modelAdmissionProbeEvidenceCeiling+1)
	if err != nil {
		return fmt.Errorf("probe evidence: %w", err)
	}
	if len(passing) > modelAdmissionProbeEvidenceCeiling {
		return errors.New("model admission pool-proven: probe evidence ceiling exceeded")
	}
	probes := map[poolProvenPair]StoredModelAdmissionProbeEvidence{}
	for _, p := range passing {
		if p.Record.EvaluatedTime().After(generatedAt) {
			continue
		}
		key := poolProvenPair{p.Record.ArtifactHashAlgorithm, p.Record.ArtifactHash}
		if _, ok := probes[key]; !ok {
			probes[key] = p
		}
	}
	rows := BuildModelAdmissionPoolProvenRows(counted, probes, modelAdmissionIntakeKAnonymityMin)
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return fmt.Errorf("nonce: %w", err)
	}
	body, err := json.Marshal(map[string]any{
		"schema":          modelAdmissionPoolProvenSchema,
		"nonce":           hex.EncodeToString(nonce[:]),
		"generated_at":    generatedAt.Format(time.RFC3339),
		"window_start":    windowStart.Format(time.RFC3339),
		"window_end":      generatedAt.Format(time.RFC3339),
		"k_anonymity_min": modelAdmissionIntakeKAnonymityMin,
		"rows":            rows,
	})
	if err != nil {
		return fmt.Errorf("encode: %w", err)
	}
	s.modelAdmissionPPMu.Lock()
	s.modelAdmissionPPSnap = &modelAdmissionPoolProvenSnapshot{generatedAt: generatedAt, body: body}
	s.modelAdmissionPPMu.Unlock()
	return nil
}

func (s *Server) refreshModelAdmissionPoolProven() {
	if err := s.buildModelAdmissionPoolProvenSnapshot(context.Background()); err != nil {
		s.log.Warn().Err(err).Msg("model admission pool-proven snapshot build failed; previous snapshot retained")
	}
}

func (s *Server) runModelAdmissionPoolProvenLoop() {
	s.refreshModelAdmissionPoolProven()
	ticker := time.NewTicker(modelAdmissionIntakeCadence)
	defer ticker.Stop()
	for range ticker.C {
		s.refreshModelAdmissionPoolProven()
	}
}

// currentModelAdmissionPoolProven returns the snapshot when it exists, is not
// older than two cadences, and is not dated in the future.
func (s *Server) currentModelAdmissionPoolProven() (*modelAdmissionPoolProvenSnapshot, bool) {
	s.modelAdmissionPPMu.RLock()
	snap := s.modelAdmissionPPSnap
	s.modelAdmissionPPMu.RUnlock()
	if snap == nil {
		return nil, false
	}
	if age := s.now().UTC().Sub(snap.generatedAt); age > modelAdmissionIntakeStaleAfter || age < 0 {
		return nil, false
	}
	return snap, true
}

func (s *Server) handleAdminModelAdmissionPoolProven(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "method not allowed"))
		return
	}
	if _, ok := s.authorizedModelAdmissionOperator(w, r); !ok {
		return
	}
	if len(r.URL.Query()) != 0 {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "no query parameters are accepted"))
		return
	}
	snap, ok := s.currentModelAdmissionPoolProven()
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("pool_proven_unavailable", "model admission pool-proven snapshot is unavailable"))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(snap.body)
}
