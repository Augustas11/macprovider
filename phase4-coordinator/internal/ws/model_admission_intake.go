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
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// SPEC-047 v0.1.6 R009 — GET /admin/model-admission/intake: the SPEC-023
// §16.2(b) `distinct_provider_offer_count` source. A materialized snapshot,
// rebuilt on a fixed cadence from the DISTINCT (provider, intake_model_key)
// pairs of the trailing 30 days (bounded by providers × keys, never by event
// volume), with sanctioned providers excluded and — where the deployment
// operates hardware trust — only providers holding an active trust root
// counted; suppressed below the fixed SPEC-023-owned k-anonymity floor.
// Aggregated only: no provider field. GET reads the snapshot; a missing or
// stale snapshot is `intake_unavailable` (503), never a partial count.

const (
	modelAdmissionIntakeSchema   = "model_admission_intake_offer_counts.v1"
	modelAdmissionIntakeSchemaV2 = "model_admission_intake_offer_counts.v2"
	// modelAdmissionIntakeArtifactKeyPrefix marks a SPEC-047 v0.2.5
	// hash-derived intake key `artifact/<algorithm>/<hash>`.
	modelAdmissionIntakeArtifactKeyPrefix = "artifact/"
	modelAdmissionIntakeWindow            = 30 * 24 * time.Hour
	modelAdmissionIntakeKAnonymityMin     = 3
	modelAdmissionIntakeCadence           = 15 * time.Minute
	modelAdmissionIntakeStaleAfter        = 2 * modelAdmissionIntakeCadence
	modelAdmissionIntakeBuildTimeout      = 10 * time.Second
	modelAdmissionIntakePairCeiling       = 100_000
)

var errModelAdmissionIntakeCeiling = errors.New("model admission intake: pair ceiling exceeded")

// ModelAdmissionIntakePair is one DISTINCT (provider, intake key) pair.
type ModelAdmissionIntakePair struct {
	ProviderID     string
	IntakeModelKey string
}

// ModelAdmissionIntakeRow is one `rows` element.
type ModelAdmissionIntakeRow struct {
	CatalogModelKey            string `json:"catalog_model_key"`
	DistinctProviderOfferCount *int   `json:"distinct_provider_offer_count"`
	Suppressed                 bool   `json:"suppressed"`
}

// modelAdmissionIntakeSnapshot is the materialized response.
type modelAdmissionIntakeSnapshot struct {
	generatedAt time.Time
	body        []byte
	// bodyV2 is the opt-in v2 frame built from the same pair scan.
	bodyV2 []byte
}

// ModelAdmissionIntakeRowV2 is one v2 `rows` element: the key member is
// named intake_model_key and holds a catalog key or a hash-derived key.
type ModelAdmissionIntakeRowV2 struct {
	IntakeModelKey             string `json:"intake_model_key"`
	DistinctProviderOfferCount *int   `json:"distinct_provider_offer_count"`
	Suppressed                 bool   `json:"suppressed"`
}

// hashDerivedModelAdmissionIntakeKey is the SPEC-047 v0.2.5 (SPEC-023-R026)
// intake key of an offer that resolves to no catalog key: the single offered
// pair whose SPEC-010 algorithm is format-compatible with the signed runtime
// source, as `artifact/<algorithm>/<hash>`. No compatible pair, or a
// malformed hash, yields no key; the provider's model name is never used.
func hashDerivedModelAdmissionIntakeKey(runtimeSource string, artifactHashes map[string]string) string {
	format, ok := poolmanifest.RuntimeSourceFormat(modelAdmissionRuntimeClass(runtimeSource))
	if !ok {
		return ""
	}
	hash := artifactHashes[format]
	if !validModelAdmissionSHA256Hex(hash) {
		return ""
	}
	return modelAdmissionIntakeArtifactKeyPrefix + format + "/" + hash
}

// isHashDerivedModelAdmissionIntakeKey reports whether a recorded intake key
// is hash-derived (excluded from the v1 frame).
func isHashDerivedModelAdmissionIntakeKey(key string) bool {
	return strings.HasPrefix(key, modelAdmissionIntakeArtifactKeyPrefix)
}

// modelAdmissionIntakeState is embedded in Server.
type modelAdmissionIntakeState struct {
	modelAdmissionIntakeMu sync.RWMutex
	modelAdmissionIntake   *modelAdmissionIntakeSnapshot
}

// BuildModelAdmissionIntakeRows applies the R009 counting and suppression
// rules to distinct pairs: a provider counts once per key; `eligible` is
// evaluated once per provider after the pair scan (an unreadable source
// aborts the build); counts below k are reported as null + suppressed. Rows
// are ordered by key.
func BuildModelAdmissionIntakeRows(ctx context.Context, pairs []ModelAdmissionIntakePair, eligible func(context.Context, string) (bool, error), k int) ([]ModelAdmissionIntakeRow, error) {
	providersByKey := map[string]map[string]struct{}{}
	eligibility := map[string]bool{}
	for _, pair := range pairs {
		if pair.IntakeModelKey == "" || pair.ProviderID == "" {
			continue
		}
		ok, seen := eligibility[pair.ProviderID]
		if !seen {
			ok = true
			if eligible != nil {
				var err error
				ok, err = eligible(ctx, pair.ProviderID)
				if err != nil {
					return nil, fmt.Errorf("provider eligibility: %w", err)
				}
			}
			eligibility[pair.ProviderID] = ok
		}
		if !ok {
			continue
		}
		set := providersByKey[pair.IntakeModelKey]
		if set == nil {
			set = map[string]struct{}{}
			providersByKey[pair.IntakeModelKey] = set
		}
		set[pair.ProviderID] = struct{}{}
	}
	keys := make([]string, 0, len(providersByKey))
	for key := range providersByKey {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	rows := make([]ModelAdmissionIntakeRow, 0, len(keys))
	for _, key := range keys {
		n := len(providersByKey[key])
		if n < k {
			rows = append(rows, ModelAdmissionIntakeRow{CatalogModelKey: key, Suppressed: true})
			continue
		}
		count := n
		rows = append(rows, ModelAdmissionIntakeRow{CatalogModelKey: key, DistinctProviderOfferCount: &count})
	}
	return rows, nil
}

// providerIntakeSanctioned is the SPEC-047 R009 closed current-state
// `provider_intake_sanctioned(provider_id, at)` predicate:
//
//	(1) route        — SPEC-011 provisional admission `rejected`, or a
//	                   persisted SPEC-032 canary sanction with fail_count > 0;
//	(2) trust        — no hardware-trust root active at `at` (expired, revoked, or never held);
//	(3) payout       — no per-provider payout sanction exists in v0.1.6;
//	(4) registration — a revoked SPEC-002 provider token and no active one.
//
// A sanction class the deployment does not operate (no trust store; no
// token issuer) contributes no sanction; a wired source that cannot be read
// — including an issuer wired without its custody history — returns an
// error and the caller fails closed.
func (s *Server) providerIntakeSanctioned(ctx context.Context, providerID string, at time.Time) (bool, error) {
	if s.admission != nil && s.admission.Rejected(providerID) {
		return true, nil
	}
	if s.pool != nil {
		for _, sanction := range s.pool.CanarySanctions() {
			if sanction.ProviderID == providerID && sanction.FailCount > 0 {
				return true, nil
			}
		}
	}
	if s.hardwareTrustAdmin != nil {
		_, active, err := s.hardwareTrustAdmin.ProviderHardwareTrustState(ctx, providerID, at)
		if err != nil {
			return false, fmt.Errorf("hardware trust: %w", err)
		}
		if !active {
			return true, nil
		}
	}
	if s.issuer != nil {
		history, ok := s.tokens.(providerTokenCustodyHistoryStore)
		if !ok || history == nil {
			return false, errors.New("token issuer wired without custody history")
		}
		revoked, err := history.HasRevokedTokenForProvider(ctx, providerID)
		if err != nil {
			return false, fmt.Errorf("token custody: %w", err)
		}
		if revoked {
			active, err := s.issuer.HasActiveTokenForProvider(ctx, providerID)
			if err != nil {
				return false, fmt.Errorf("token issuer: %w", err)
			}
			if !active {
				return true, nil
			}
		}
	}
	return false, nil
}

// providerIntakeEligible is R009's counting eligibility: not sanctioned by
// the predicate above, whose trust category already requires an active
// root at `at` whenever the deployment operates hardware trust (a
// never-trusted registration is not supply evidence).
func (s *Server) providerIntakeEligible(ctx context.Context, providerID string, at time.Time) (bool, error) {
	sanctioned, err := s.providerIntakeSanctioned(ctx, providerID, at)
	if err != nil {
		return false, err
	}
	return !sanctioned, nil
}

// buildModelAdmissionIntakeSnapshot materializes the aggregate as one
// bounded job (SPEC-047 R009): the pair scan first, then eligibility once per
// provider as of the build instant, a query timeout, a pair ceiling, and
// every wired source readable — otherwise no snapshot is produced and the
// previous one stays in place. The pointer is swapped once, at the end.
func (s *Server) buildModelAdmissionIntakeSnapshot(ctx context.Context) error {
	if s.modelAdmissions == nil {
		return errors.New("model admission store unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, modelAdmissionIntakeBuildTimeout)
	defer cancel()
	generatedAt := s.now().UTC().Truncate(time.Second)
	windowStart := generatedAt.Add(-modelAdmissionIntakeWindow)
	pairs, err := s.modelAdmissions.ModelAdmissionIntakeOfferPairs(ctx, windowStart, generatedAt, modelAdmissionIntakePairCeiling+1)
	if err != nil {
		return fmt.Errorf("offer pairs: %w", err)
	}
	if len(pairs) > modelAdmissionIntakePairCeiling {
		return errModelAdmissionIntakeCeiling
	}
	eligibility := map[string]bool{}
	eligible := func(c context.Context, providerID string) (bool, error) {
		if ok, seen := eligibility[providerID]; seen {
			return ok, nil
		}
		ok, err := s.providerIntakeEligible(c, providerID, generatedAt)
		if err == nil {
			eligibility[providerID] = ok
		}
		return ok, err
	}
	allRows, err := BuildModelAdmissionIntakeRows(ctx, pairs, eligible, modelAdmissionIntakeKAnonymityMin)
	if err != nil {
		return err
	}
	// The v1 frame never carries a hash-derived key (SPEC-047 v0.2.5); the
	// v2 frame carries every key from the same scan.
	rows := make([]ModelAdmissionIntakeRow, 0, len(allRows))
	rowsV2 := make([]ModelAdmissionIntakeRowV2, 0, len(allRows))
	for _, row := range allRows {
		rowsV2 = append(rowsV2, ModelAdmissionIntakeRowV2{IntakeModelKey: row.CatalogModelKey, DistinctProviderOfferCount: row.DistinctProviderOfferCount, Suppressed: row.Suppressed})
		if !isHashDerivedModelAdmissionIntakeKey(row.CatalogModelKey) {
			rows = append(rows, row)
		}
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return fmt.Errorf("nonce: %w", err)
	}
	frame := func(schema string, rows any) ([]byte, error) {
		return json.Marshal(map[string]any{
			"schema":          schema,
			"nonce":           hex.EncodeToString(nonce[:]),
			"generated_at":    generatedAt.Format(time.RFC3339),
			"window_start":    windowStart.Format(time.RFC3339),
			"window_end":      generatedAt.Format(time.RFC3339),
			"k_anonymity_min": modelAdmissionIntakeKAnonymityMin,
			"rows":            rows,
		})
	}
	body, err := frame(modelAdmissionIntakeSchema, rows)
	if err != nil {
		return fmt.Errorf("encode: %w", err)
	}
	bodyV2, err := frame(modelAdmissionIntakeSchemaV2, rowsV2)
	if err != nil {
		return fmt.Errorf("encode v2: %w", err)
	}
	s.modelAdmissionIntakeMu.Lock()
	s.modelAdmissionIntake = &modelAdmissionIntakeSnapshot{generatedAt: generatedAt, body: body, bodyV2: bodyV2}
	s.modelAdmissionIntakeMu.Unlock()
	return nil
}

func (s *Server) runModelAdmissionIntakeLoop() {
	build := func() {
		if err := s.buildModelAdmissionIntakeSnapshot(context.Background()); err != nil {
			s.log.Warn().Err(err).Msg("model admission intake snapshot build failed; previous snapshot retained")
		}
	}
	build()
	ticker := time.NewTicker(modelAdmissionIntakeCadence)
	defer ticker.Stop()
	for range ticker.C {
		build()
	}
}

// currentModelAdmissionIntake returns the snapshot when it exists and is
// not older than two cadences.
func (s *Server) currentModelAdmissionIntake() (*modelAdmissionIntakeSnapshot, bool) {
	s.modelAdmissionIntakeMu.RLock()
	snap := s.modelAdmissionIntake
	s.modelAdmissionIntakeMu.RUnlock()
	// Freshness is two-sided: a snapshot older than two cadences OR dated
	// in the future (clock step) is unavailable, never served as current.
	if snap == nil {
		return nil, false
	}
	if age := s.now().UTC().Sub(snap.generatedAt); age > modelAdmissionIntakeStaleAfter || age < 0 {
		return nil, false
	}
	return snap, true
}

func (s *Server) handleAdminModelAdmissionIntake(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "method not allowed"))
		return
	}
	if _, ok := s.authorizedModelAdmissionOperator(w, r); !ok {
		return
	}
	// SPEC-047 v0.2.5: the only accepted query parameter is the opt-in
	// schema=model_admission_intake_offer_counts.v2.
	query := r.URL.Query()
	wantV2 := false
	switch {
	case len(query) == 0:
	case len(query) == 1 && len(query["schema"]) == 1 && query.Get("schema") == modelAdmissionIntakeSchemaV2:
		wantV2 = true
	default:
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "only schema=model_admission_intake_offer_counts.v2 is accepted"))
		return
	}
	snap, ok := s.currentModelAdmissionIntake()
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("intake_unavailable", "model admission intake snapshot is unavailable"))
		return
	}
	body := snap.body
	if wantV2 {
		body = snap.bodyV2
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}
