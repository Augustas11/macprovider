package ws

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/jcs"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

const (
	modelAdmissionOfferSubmitSchema      = "model_admission_offer_submit.v1"
	modelAdmissionStatusSchema           = "model_admission_status.v1"
	modelAdmissionWithdrawRequestSchema  = "model_admission_withdraw_request.v1"
	modelAdmissionWithdrawResponseSchema = "model_admission_withdraw.v1"
	modelAdmissionOfferDomain            = "macprovider.model_admission.offer.v1"
	modelAdmissionWithdrawDomain         = "macprovider.model_admission.withdraw.v1"
	modelAdmissionOfferSubmitted         = "offer_submitted"
	modelAdmissionNotOffered             = "not_offered"
	modelAdmissionWithdrawn              = "withdrawn"
	modelAdmissionRevoked                = "revoked"
	modelAdmissionActorProvider          = "provider"
	modelAdmissionActorCoordinator       = "coordinator"
	modelAdmissionMaxBodyBytes           = 64 * 1024
	modelAdmissionMaxEvents              = 256
	modelAdmissionMaxCandidates          = 64
	modelAdmissionMaxClockSkew           = 5 * time.Minute
	// modelAdmissionSubmissionsDisabledCode is the closed, non-leaking
	// rejection reason returned while the #1248 offer-submit policy gate is
	// engaged. It is a transport-level error code, not a SPEC-047-R001
	// admission state or a SPEC-046-R003 provider_guidance value.
	modelAdmissionSubmissionsDisabledCode = "submissions_disabled"
)

var (
	errModelAdmissionReplayConflict = errors.New("model admission replay conflict")
	// errModelAdmissionStaleHead: the operator's expected head is no longer the
	// candidate's latest event (SPEC-047-R001 v0.1.5 `stale_head`).
	errModelAdmissionStaleHead      = errors.New("model admission stale head")
	errModelAdmissionCapExceeded    = errors.New("model admission cap exceeded")
	errModelAdmissionRateLimited    = errors.New("model admission rate limited")
	modelAdmissionCandidatePattern  = regexp.MustCompile(`^byom_[a-z2-7]{52}$`)
	modelAdmissionCLIVersionPattern = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$`)
	modelAdmissionServedRefPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$`)
)

type ModelAdmissionStore interface {
	AppendModelAdmissionOffer(context.Context, ModelAdmissionEvent) (ModelAdmissionEvent, bool, error)
	AppendModelAdmissionWithdrawal(context.Context, ModelAdmissionEvent) (ModelAdmissionEvent, bool, error)
	AppendModelAdmissionDecision(context.Context, ModelAdmissionEvent) (ModelAdmissionEvent, error)
	LatestModelAdmissionStatus(context.Context, string, string) (ModelAdmissionEvent, bool, error)
	LatestModelAdmissionRouteStatus(context.Context, string, string, string) (ModelAdmissionEvent, bool, error)
	SettlementCapableModelAdmissionStatusesForServedModel(context.Context, string, string) ([]ModelAdmissionEvent, error)
	// SPEC-047-R001 v0.1.5 operator decision path.
	// CASAppendModelAdmissionDecision appends a coordinator/operator decision
	// only when the candidate's head still equals expectedHead (after
	// idempotency resolution — a replay answers the original event whatever
	// the head); errModelAdmissionStaleHead otherwise.
	CASAppendModelAdmissionDecision(context.Context, ModelAdmissionEvent, string) (ModelAdmissionEvent, bool, error)
	// AppendModelAdmissionApproval is CASAppendModelAdmissionDecision that,
	// in the same atomic step, marks the approved pending record consumed by
	// this approval (every other open record for the candidate is
	// invalidated, as on any append).
	AppendModelAdmissionApproval(context.Context, ModelAdmissionEvent, string, PendingModelAdmissionApproval) (ModelAdmissionEvent, bool, error)
	// LatestModelAdmissionStatusesForProvider is the latest event of every
	// candidate of one provider (the operator listing), ordered by candidate id.
	LatestModelAdmissionStatusesForProvider(context.Context, string) ([]ModelAdmissionEvent, error)
	// LatestModelAdmissionStatusesInStates is the latest event of every
	// candidate of every provider whose state is one of states (reload sweeps).
	LatestModelAdmissionStatusesInStates(context.Context, []string) ([]ModelAdmissionEvent, error)
	// ModelAdmissionEventByRequestID is the operator idempotency lookup: the
	// event a (provider_id, request_id) pair originally produced.
	ModelAdmissionEventByRequestID(context.Context, string, string) (ModelAdmissionEvent, bool, error)
	// Dual-control pending decisions.
	CreatePendingModelAdmissionDecision(context.Context, PendingModelAdmissionDecision) (PendingModelAdmissionDecision, bool, error)
	PendingModelAdmissionDecision(context.Context, string) (PendingModelAdmissionDecision, bool, error)
	PendingModelAdmissionDecisionByRequest(context.Context, string, string, string) (PendingModelAdmissionDecision, bool, error)
	InvalidatePendingModelAdmissionDecisions(context.Context, string, string) error
}

type ModelAdmissionEvent struct {
	CoordinatorEventID                string
	Actor                             string
	ProviderID                        string
	CandidateID                       string
	ServedModelRef                    string
	CatalogModelKey                   string
	CatalogID                         string
	CatalogBodyDigest                 string
	CatalogSignatureKeyID             string
	CatalogSignaturePubkeyFingerprint string
	ExpectedCatalogModelHash          string
	ExpectedCatalogModelHashAlgorithm string
	DiscoveryDigestSHA256             string
	EvaluationDigestSHA256            string
	RequestedDisclosureClass          string
	PreviousState                     string
	State                             string
	NextState                         string
	ReasonCode                        string
	RequestID                         string
	Nonce                             string
	PayloadDigestSHA256               string
	SignatureDigestSHA256             string
	CreatedAt                         time.Time
	// SPEC-047 v0.1.5 recorded catalog match (offer events) and decision
	// bindings (operator decisions). RuntimeSource is the offer's signed
	// runtime source; the row tuple and release tuple are read from the
	// authenticated candidate catalog; members are the admissible tagged
	// member set; the six Artifact* values bind a feed member at decision
	// time; EvaluatedReleaseGeneration is the release generation the
	// decision evaluated under.
	RuntimeSource                  string
	CatalogMatchState              string
	CatalogMatchReason             string
	CatalogRowModelID              string
	CatalogRowModelSHA256          string
	CatalogReleaseID               string
	CatalogCandidateSHA256         string
	CatalogSignerKeyID             string
	CatalogMembers                 []ModelAdmissionCatalogMember
	ArtifactFeedSHA256             string
	ArtifactID                     string
	ArtifactHash                   string
	ArtifactHashAlgorithm          string
	ArtifactFeedSignerKeyID        string
	ArtifactCandidateCatalogSHA256 string
	BoundMemberSource              string
	EvaluatedReleaseGeneration     uint64
}

// ModelAdmissionCatalogMember is one recorded, admissible member of the
// offer's catalog match (SPEC-047-R001 v0.1.5): `Source` is `candidate_row`
// (the row's own primary pair; artifact id and provenance null) or
// `artifact_feed` (artifact id and the provenance of the identity set it
// resolved in, all non-null).
type ModelAdmissionCatalogMember struct {
	Source                         string `json:"source"`
	HashAlgorithm                  string `json:"hash_algorithm"`
	Hash                           string `json:"hash"`
	ArtifactID                     string `json:"artifact_id,omitempty"`
	ArtifactFeedSHA256             string `json:"artifact_feed_sha256,omitempty"`
	ArtifactFeedSignerKeyID        string `json:"artifact_feed_signer_key_id,omitempty"`
	ArtifactCandidateCatalogSHA256 string `json:"artifact_candidate_catalog_sha256,omitempty"`
}

const (
	modelAdmissionMemberSourceCandidateRow = "candidate_row"
	modelAdmissionMemberSourceArtifactFeed = "artifact_feed"
	modelAdmissionCatalogMatched           = "catalog_matched"
	modelAdmissionCatalogUnmatched         = "unmatched"
)

func encodeModelAdmissionCatalogMembers(members []ModelAdmissionCatalogMember) string {
	if len(members) == 0 {
		return ""
	}
	raw, err := json.Marshal(members)
	if err != nil {
		return ""
	}
	return string(raw)
}

// decodeModelAdmissionCatalogMembers distinguishes an empty member set
// (legacy row, unmatched offer) from a corrupt column, which is a scan error.
func decodeModelAdmissionCatalogMembers(raw string) ([]ModelAdmissionCatalogMember, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	var members []ModelAdmissionCatalogMember
	if err := json.Unmarshal([]byte(raw), &members); err != nil {
		return nil, fmt.Errorf("model admission catalog_members_json: %w", err)
	}
	return members, nil
}

// PendingModelAdmissionApproval identifies the approval that consumes a
// pending decision: the record, the approval's replay key and body digest,
// and the approving actor.
type PendingModelAdmissionApproval struct {
	PendingID  string
	RequestKey string
	Digest     string
	Actor      string
}

// PendingModelAdmissionDecision is a dual-control `settlement_capable`
// request awaiting approval by a distinct operator actor (SPEC-047-R001
// v0.1.5): it appends nothing until approved, is consumed by exactly one
// approval, expires unused, and is invalidated by any event appended for the
// candidate.
type PendingModelAdmissionDecision struct {
	ID            string
	ProviderID    string
	CandidateID   string
	NextState     string
	ReasonCode    string
	RequestDigest string
	RequestID     string
	EvaluatedHead string
	RequestedBy   string
	// The pending response is answered from the RECORD on replay, whatever
	// the head did since: the state at evaluation, the candidate's served
	// reference and resolved key.
	AdmissionState     string
	ServedModelRef     string
	CatalogModelKey    string
	CreatedAt          time.Time
	ExpiresAt          time.Time
	ConsumedAt         time.Time
	ConsumedBy         string
	ConsumedEventID    string
	Invalidated        bool
	ApprovalRequestKey string
	ApprovalDigest     string
}

type memoryModelAdmissionStore struct {
	mu            sync.Mutex
	events        []ModelAdmissionEvent
	latest        map[string]ModelAdmissionEvent
	requestIDs    map[string]ModelAdmissionEvent
	nonces        map[string]ModelAdmissionEvent
	candidates    map[string]map[string]struct{}
	providerEvent map[string][]time.Time
	pending       map[string]PendingModelAdmissionDecision
	pendingByReq  map[string]string
}

func NewMemoryModelAdmissionStore() ModelAdmissionStore {
	return &memoryModelAdmissionStore{
		latest:        map[string]ModelAdmissionEvent{},
		requestIDs:    map[string]ModelAdmissionEvent{},
		nonces:        map[string]ModelAdmissionEvent{},
		candidates:    map[string]map[string]struct{}{},
		providerEvent: map[string][]time.Time{},
	}
}

func (s *memoryModelAdmissionStore) AppendModelAdmissionOffer(_ context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	return s.appendProviderModelAdmissionEvent(event, modelAdmissionOfferSubmitted)
}

func (s *memoryModelAdmissionStore) AppendModelAdmissionWithdrawal(_ context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	return s.appendProviderModelAdmissionEvent(event, modelAdmissionWithdrawn)
}

func (s *memoryModelAdmissionStore) AppendModelAdmissionDecision(_ context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	stored, _, err := s.appendCoordinatorModelAdmissionEvent(event, "", nil)
	return stored, err
}

func (s *memoryModelAdmissionStore) CASAppendModelAdmissionDecision(_ context.Context, event ModelAdmissionEvent, expectedHead string) (ModelAdmissionEvent, bool, error) {
	return s.appendCoordinatorModelAdmissionEvent(event, expectedHead, nil)
}

func (s *memoryModelAdmissionStore) AppendModelAdmissionApproval(_ context.Context, event ModelAdmissionEvent, expectedHead string, approval PendingModelAdmissionApproval) (ModelAdmissionEvent, bool, error) {
	return s.appendCoordinatorModelAdmissionEvent(event, expectedHead, &approval)
}

func (s *memoryModelAdmissionStore) appendProviderModelAdmissionEvent(event ModelAdmissionEvent, nextState string) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := event.CreatedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	event.CreatedAt = now.UTC()
	if replayed, matched, conflict := s.resolveModelAdmissionReplay(event); conflict {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	} else if matched {
		return replayed, true, nil
	}
	window := pruneModelAdmissionWindow(s.providerEvent[event.ProviderID], now)
	if len(window) >= modelAdmissionMaxEvents {
		return ModelAdmissionEvent{}, false, errModelAdmissionRateLimited
	}
	candidateSet := s.candidates[event.ProviderID]
	if candidateSet == nil {
		candidateSet = map[string]struct{}{}
		s.candidates[event.ProviderID] = candidateSet
	}
	if _, known := candidateSet[event.CandidateID]; !known && len(candidateSet) >= modelAdmissionMaxCandidates {
		return ModelAdmissionEvent{}, false, errModelAdmissionCapExceeded
	}
	previousState := modelAdmissionNotOffered
	if previous, ok := s.latest[event.ProviderID+"|"+event.CandidateID]; ok {
		previousState = previous.State
		if !sameModelAdmissionTuple(previous, event) {
			return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
		}
		if nextState == modelAdmissionWithdrawn {
			event = modelAdmissionEventWithPriorEvidence(event, previous)
		}
		if modelAdmissionRequiresRefreshedEvidence(previousState) && !modelAdmissionEvidenceRefreshed(previous, event) {
			return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
		}
	}
	if !modelAdmissionProviderTransitionAllowed(previousState, nextState) {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	event = prepareModelAdmissionTransition(event, previousState, modelAdmissionActorProvider, nextState)
	candidateSet[event.CandidateID] = struct{}{}
	s.providerEvent[event.ProviderID] = append(window, now)
	s.events = append(s.events, event)
	s.latest[event.ProviderID+"|"+event.CandidateID] = event
	s.requestIDs[event.ProviderID+"|"+event.RequestID] = event
	s.nonces[event.ProviderID+"|"+event.Nonce] = event
	s.invalidatePendingLocked(event.ProviderID, event.CandidateID)
	return event, false, nil
}

// resolveModelAdmissionReplay resolves an event's replay keys against prior
// events. It inspects EVERY supplied non-empty key (request_id and nonce) before
// deciding, so a split-key event — one key bound to event A, the other to event
// B — is never mistaken for a replay: conflict=true if any supplied key is bound
// to a prior event with a different payload digest, or if two supplied keys map
// to different stored events. matched=true (with the stored event) is returned
// only when every supplied key agrees on the same event and payload — a true
// idempotent replay. Empty keys never match. Caller must hold s.mu. Used by both
// provider and coordinator memory appends for identical replay semantics.
func (s *memoryModelAdmissionStore) resolveModelAdmissionReplay(event ModelAdmissionEvent) (ModelAdmissionEvent, bool, bool) {
	var matched *ModelAdmissionEvent
	// consider folds one key's binding into the decision, returning conflict.
	consider := func(existing ModelAdmissionEvent, found bool) bool {
		if !found {
			return false
		}
		if existing.PayloadDigestSHA256 != event.PayloadDigestSHA256 {
			return true
		}
		if matched == nil {
			bound := existing
			matched = &bound
		} else if matched.CoordinatorEventID != existing.CoordinatorEventID {
			return true
		}
		return false
	}
	if event.RequestID != "" {
		existing, ok := s.requestIDs[event.ProviderID+"|"+event.RequestID]
		if consider(existing, ok) {
			return ModelAdmissionEvent{}, false, true
		}
	}
	if event.Nonce != "" {
		existing, ok := s.nonces[event.ProviderID+"|"+event.Nonce]
		if consider(existing, ok) {
			return ModelAdmissionEvent{}, false, true
		}
	}
	if matched != nil {
		return *matched, true, false
	}
	return ModelAdmissionEvent{}, false, false
}

func (s *memoryModelAdmissionStore) appendCoordinatorModelAdmissionEvent(event ModelAdmissionEvent, expectedHead string, approval *PendingModelAdmissionApproval) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := event.CreatedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	event.CreatedAt = now.UTC()
	// Generate any missing replay keys up front. fillCoordinatorModelAdmissionReplayKeys
	// is deterministic and state-independent, so keyless decisions get the same
	// keys on every retry. The replay resolution then runs before latest-state
	// transition validation so an idempotent retry — explicit-key OR generated-key
	// — stays state-order independent: a decision replayed after the admission has
	// advanced to a later state (or already equals the target state) resolves as a
	// replay, not a transition conflict. Mirrors the provider append ordering.
	event = fillCoordinatorModelAdmissionReplayKeys(event)
	if replayed, matched, conflict := s.resolveModelAdmissionReplay(event); conflict {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	} else if matched {
		return replayed, true, nil
	}
	previous, ok := s.latest[event.ProviderID+"|"+event.CandidateID]
	if !ok || !sameModelAdmissionTuple(previous, event) {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	if expectedHead != "" && previous.CoordinatorEventID != expectedHead {
		return ModelAdmissionEvent{}, false, errModelAdmissionStaleHead
	}
	if !modelAdmissionCoordinatorTransitionAllowed(previous.State, event.State) {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	if modelAdmissionTransitionRequiresCatalogAuthority(event.State) && !modelAdmissionEventHasTrustedCatalogAuthority(event) {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	if modelAdmissionTransitionReasonRequired(previous.State, event.State) && strings.TrimSpace(event.ReasonCode) == "" {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	actor := modelAdmissionActorCoordinator
	if strings.HasPrefix(event.Actor, "operator:") {
		actor = event.Actor
	}
	event = prepareModelAdmissionTransition(event, previous.State, actor, event.State)
	s.events = append(s.events, event)
	s.latest[event.ProviderID+"|"+event.CandidateID] = event
	s.requestIDs[event.ProviderID+"|"+event.RequestID] = event
	s.nonces[event.ProviderID+"|"+event.Nonce] = event
	s.invalidatePendingLocked(event.ProviderID, event.CandidateID)
	if approval != nil {
		s.consumePendingLocked(*approval, event)
	}
	return event, false, nil
}

func (s *memoryModelAdmissionStore) ModelAdmissionEventByRequestID(_ context.Context, providerID, requestID string) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	event, ok := s.requestIDs[providerID+"|"+requestID]
	return event, ok, nil
}

func (s *memoryModelAdmissionStore) LatestModelAdmissionStatusesForProvider(_ context.Context, providerID string) ([]ModelAdmissionEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []ModelAdmissionEvent
	for key, event := range s.latest {
		if strings.HasPrefix(key, providerID+"|") {
			out = append(out, event)
		}
	}
	sortModelAdmissionEventsByCandidate(out)
	return out, nil
}

func (s *memoryModelAdmissionStore) LatestModelAdmissionStatusesInStates(_ context.Context, states []string) ([]ModelAdmissionEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	want := map[string]struct{}{}
	for _, state := range states {
		want[state] = struct{}{}
	}
	var out []ModelAdmissionEvent
	for _, event := range s.latest {
		if _, ok := want[event.State]; ok {
			out = append(out, event)
		}
	}
	sortModelAdmissionEventsByCandidate(out)
	return out, nil
}

func (s *memoryModelAdmissionStore) LatestModelAdmissionStatus(_ context.Context, providerID, candidateID string) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	event, ok := s.latest[providerID+"|"+candidateID]
	return event, ok, nil
}

func (s *memoryModelAdmissionStore) LatestModelAdmissionRouteStatus(_ context.Context, providerID, servedModelRef, catalogModelKey string) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return latestModelAdmissionRouteStatusFromEvents(s.events, providerID, servedModelRef, catalogModelKey)
}

func (s *memoryModelAdmissionStore) SettlementCapableModelAdmissionStatusesForServedModel(_ context.Context, providerID, servedModelRef string) ([]ModelAdmissionEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	servedModelRef = strings.TrimSpace(servedModelRef)
	seen := map[string]struct{}{}
	events := make([]ModelAdmissionEvent, 0)
	for i := len(s.events) - 1; i >= 0; i-- {
		event := s.events[i]
		if event.ProviderID != providerID || event.ServedModelRef != servedModelRef {
			continue
		}
		key := event.ProviderID + "|" + event.CandidateID
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		latest := s.latest[key]
		if ModelAdmissionSettlementStateCandidate(latest) {
			events = append(events, latest)
		}
	}
	return events, nil
}

type SQLiteModelAdmissionStore struct {
	db *sql.DB
}

func NewSQLiteModelAdmissionStore(db *sql.DB) (*SQLiteModelAdmissionStore, error) {
	if db == nil {
		return nil, fmt.Errorf("db is required")
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE TABLE IF NOT EXISTS model_admission_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id TEXT NOT NULL,
    candidate_id TEXT NOT NULL,
    served_model_ref TEXT NOT NULL,
    catalog_model_key TEXT NOT NULL,
    catalog_id TEXT NOT NULL DEFAULT '',
    catalog_body_digest TEXT NOT NULL DEFAULT '',
    catalog_signature_key_id TEXT NOT NULL DEFAULT '',
    catalog_signature_pubkey_fingerprint TEXT NOT NULL DEFAULT '',
    expected_catalog_model_hash TEXT NOT NULL DEFAULT '',
    expected_catalog_model_hash_algorithm TEXT NOT NULL DEFAULT '',
    discovery_digest_sha256 TEXT NOT NULL,
    evaluation_digest_sha256 TEXT NOT NULL,
    requested_disclosure_class TEXT NOT NULL,
    previous_state TEXT NOT NULL,
    state TEXT NOT NULL,
    next_state TEXT NOT NULL,
    actor TEXT NOT NULL,
    coordinator_event_id TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    request_id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    payload_digest_sha256 TEXT NOT NULL,
    signature_digest_sha256 TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
)`); err != nil {
		return nil, err
	}
	if err := ensureSQLiteModelAdmissionColumns(db); err != nil {
		return nil, err
	}
	if err := ensureSQLitePendingModelAdmissionTable(db); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE UNIQUE INDEX IF NOT EXISTS model_admission_events_provider_request_id
ON model_admission_events(provider_id, request_id)`); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE UNIQUE INDEX IF NOT EXISTS model_admission_events_provider_nonce
ON model_admission_events(provider_id, nonce)`); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE INDEX IF NOT EXISTS model_admission_events_provider_route_tuple
ON model_admission_events(provider_id, served_model_ref, LOWER(catalog_model_key), id DESC)`); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE INDEX IF NOT EXISTS model_admission_events_provider_catalog
ON model_admission_events(provider_id, LOWER(catalog_model_key), id DESC)`); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE INDEX IF NOT EXISTS model_admission_events_provider_latest
ON model_admission_events(provider_id, id DESC)`); err != nil {
		return nil, err
	}
	return &SQLiteModelAdmissionStore{db: db}, nil
}

func ensureSQLiteModelAdmissionColumns(db *sql.DB) error {
	rows, err := db.QueryContext(context.Background(), `PRAGMA table_info(model_admission_events)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	columns := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		columns[name] = true
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, column := range []struct {
		name string
		sql  string
	}{
		{name: "catalog_id", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_id TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_body_digest", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_body_digest TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_signature_key_id", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_signature_key_id TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_signature_pubkey_fingerprint", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_signature_pubkey_fingerprint TEXT NOT NULL DEFAULT ''`},
		{name: "expected_catalog_model_hash", sql: `ALTER TABLE model_admission_events ADD COLUMN expected_catalog_model_hash TEXT NOT NULL DEFAULT ''`},
		{name: "expected_catalog_model_hash_algorithm", sql: `ALTER TABLE model_admission_events ADD COLUMN expected_catalog_model_hash_algorithm TEXT NOT NULL DEFAULT ''`},
		// SPEC-047 v0.1.5 recorded match + decision binding columns.
		{name: "runtime_source", sql: `ALTER TABLE model_admission_events ADD COLUMN runtime_source TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_match_state", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_match_state TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_match_reason", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_match_reason TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_row_model_id", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_row_model_id TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_row_model_sha256", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_row_model_sha256 TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_release_id", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_release_id TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_candidate_sha256", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_candidate_sha256 TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_signer_key_id", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_signer_key_id TEXT NOT NULL DEFAULT ''`},
		{name: "catalog_members_json", sql: `ALTER TABLE model_admission_events ADD COLUMN catalog_members_json TEXT NOT NULL DEFAULT ''`},
		{name: "artifact_feed_sha256", sql: `ALTER TABLE model_admission_events ADD COLUMN artifact_feed_sha256 TEXT NOT NULL DEFAULT ''`},
		{name: "artifact_id", sql: `ALTER TABLE model_admission_events ADD COLUMN artifact_id TEXT NOT NULL DEFAULT ''`},
		{name: "artifact_hash", sql: `ALTER TABLE model_admission_events ADD COLUMN artifact_hash TEXT NOT NULL DEFAULT ''`},
		{name: "artifact_hash_algorithm", sql: `ALTER TABLE model_admission_events ADD COLUMN artifact_hash_algorithm TEXT NOT NULL DEFAULT ''`},
		{name: "artifact_feed_signer_key_id", sql: `ALTER TABLE model_admission_events ADD COLUMN artifact_feed_signer_key_id TEXT NOT NULL DEFAULT ''`},
		{name: "artifact_candidate_catalog_sha256", sql: `ALTER TABLE model_admission_events ADD COLUMN artifact_candidate_catalog_sha256 TEXT NOT NULL DEFAULT ''`},
		{name: "bound_member_source", sql: `ALTER TABLE model_admission_events ADD COLUMN bound_member_source TEXT NOT NULL DEFAULT ''`},
		{name: "evaluated_release_generation", sql: `ALTER TABLE model_admission_events ADD COLUMN evaluated_release_generation INTEGER NOT NULL DEFAULT 0`},
	} {
		if columns[column.name] {
			continue
		}
		if _, err := db.ExecContext(context.Background(), column.sql); err != nil {
			return err
		}
	}
	return nil
}

func (s *SQLiteModelAdmissionStore) AppendModelAdmissionOffer(ctx context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	return s.appendProviderModelAdmissionEvent(ctx, event, modelAdmissionOfferSubmitted)
}

func (s *SQLiteModelAdmissionStore) AppendModelAdmissionWithdrawal(ctx context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	return s.appendProviderModelAdmissionEvent(ctx, event, modelAdmissionWithdrawn)
}

func (s *SQLiteModelAdmissionStore) CASAppendModelAdmissionDecision(ctx context.Context, event ModelAdmissionEvent, expectedHead string) (ModelAdmissionEvent, bool, error) {
	return s.appendCoordinatorModelAdmissionEventCAS(ctx, event, expectedHead, nil)
}

func (s *SQLiteModelAdmissionStore) AppendModelAdmissionApproval(ctx context.Context, event ModelAdmissionEvent, expectedHead string, approval PendingModelAdmissionApproval) (ModelAdmissionEvent, bool, error) {
	return s.appendCoordinatorModelAdmissionEventCAS(ctx, event, expectedHead, &approval)
}

func (s *SQLiteModelAdmissionStore) ModelAdmissionEventByRequestID(ctx context.Context, providerID, requestID string) (ModelAdmissionEvent, bool, error) {
	return scanModelAdmissionEvent(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND request_id = ?
 ORDER BY id DESC
 LIMIT 1`), providerID, requestID)
}

func (s *SQLiteModelAdmissionStore) LatestModelAdmissionStatusesForProvider(ctx context.Context, providerID string) ([]ModelAdmissionEvent, error) {
	return scanModelAdmissionEvents(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events e
  JOIN (
       SELECT MAX(id) AS latest_id
         FROM model_admission_events
        WHERE provider_id = ?
        GROUP BY provider_id, candidate_id
  ) latest ON latest.latest_id = e.id
 ORDER BY e.candidate_id ASC`), providerID)
}

func (s *SQLiteModelAdmissionStore) LatestModelAdmissionStatusesInStates(ctx context.Context, states []string) ([]ModelAdmissionEvent, error) {
	if len(states) == 0 {
		return nil, nil
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(states)), ",")
	args := make([]any, 0, len(states))
	for _, state := range states {
		args = append(args, state)
	}
	return scanModelAdmissionEvents(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events e
  JOIN (
       SELECT MAX(id) AS latest_id
         FROM model_admission_events
        GROUP BY provider_id, candidate_id
  ) latest ON latest.latest_id = e.id
 WHERE e.state IN (`+placeholders+`)
 ORDER BY e.provider_id ASC, e.candidate_id ASC`), args...)
}

func (s *SQLiteModelAdmissionStore) AppendModelAdmissionDecision(ctx context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	stored, _, err := s.appendCoordinatorModelAdmissionEvent(ctx, event)
	return stored, err
}

func (s *SQLiteModelAdmissionStore) appendProviderModelAdmissionEvent(ctx context.Context, event ModelAdmissionEvent, nextState string) (ModelAdmissionEvent, bool, error) {
	now := event.CreatedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	event.CreatedAt = now.UTC()
	var stored ModelAdmissionEvent
	var replay bool
	err := sqliteutil.Transact(ctx, s.db, func(txCtx context.Context, conn *sql.Conn) error {
		replayed, matched, conflict, err := scanSQLiteModelAdmissionReplay(txCtx, conn, event)
		if err != nil {
			return err
		}
		if conflict {
			return errModelAdmissionReplayConflict
		}
		if matched {
			stored = replayed
			replay = true
			return nil
		}
		windowStart := now.Add(-time.Hour).UTC().Format(time.RFC3339Nano)
		var eventsInWindow int
		if err := conn.QueryRowContext(txCtx, `
SELECT COUNT(*) FROM model_admission_events WHERE provider_id = ? AND created_at_utc >= ?`,
			event.ProviderID, windowStart).Scan(&eventsInWindow); err != nil {
			return err
		}
		if eventsInWindow >= modelAdmissionMaxEvents {
			return errModelAdmissionRateLimited
		}
		var candidates int
		if err := conn.QueryRowContext(txCtx, `
SELECT COUNT(DISTINCT candidate_id) FROM model_admission_events WHERE provider_id = ? AND candidate_id <> ?`,
			event.ProviderID, event.CandidateID).Scan(&candidates); err != nil {
			return err
		}
		if candidates >= modelAdmissionMaxCandidates {
			return errModelAdmissionCapExceeded
		}
		previousState := modelAdmissionNotOffered
		previous, found, err := scanModelAdmissionEvent(txCtx, conn, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND candidate_id = ?
 ORDER BY id DESC
 LIMIT 1`), event.ProviderID, event.CandidateID)
		if err != nil {
			return err
		}
		if found {
			previousState = previous.State
			if !sameModelAdmissionTuple(previous, event) {
				return errModelAdmissionReplayConflict
			}
			if nextState == modelAdmissionWithdrawn {
				event = modelAdmissionEventWithPriorEvidence(event, previous)
			}
			if modelAdmissionRequiresRefreshedEvidence(previousState) && !modelAdmissionEvidenceRefreshed(previous, event) {
				return errModelAdmissionReplayConflict
			}
		}
		if !modelAdmissionProviderTransitionAllowed(previousState, nextState) {
			return errModelAdmissionReplayConflict
		}
		event = prepareModelAdmissionTransition(event, previousState, modelAdmissionActorProvider, nextState)
		if _, err := conn.ExecContext(txCtx, `
INSERT INTO model_admission_events(
    provider_id, candidate_id, served_model_ref, catalog_model_key,
    catalog_id, catalog_body_digest, catalog_signature_key_id,
    catalog_signature_pubkey_fingerprint, expected_catalog_model_hash,
    expected_catalog_model_hash_algorithm,
    discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
    previous_state, state, next_state, actor, coordinator_event_id,
    reason_code, request_id, nonce, payload_digest_sha256,
    signature_digest_sha256, created_at_utc,
    runtime_source, catalog_match_state, catalog_match_reason,
    catalog_row_model_id, catalog_row_model_sha256, catalog_release_id,
    catalog_candidate_sha256, catalog_signer_key_id, catalog_members_json,
    artifact_feed_sha256, artifact_id, artifact_hash, artifact_hash_algorithm,
    artifact_feed_signer_key_id, artifact_candidate_catalog_sha256,
    bound_member_source, evaluated_release_generation
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			event.ProviderID,
			event.CandidateID,
			event.ServedModelRef,
			event.CatalogModelKey,
			event.CatalogID,
			event.CatalogBodyDigest,
			event.CatalogSignatureKeyID,
			event.CatalogSignaturePubkeyFingerprint,
			event.ExpectedCatalogModelHash,
			event.ExpectedCatalogModelHashAlgorithm,
			event.DiscoveryDigestSHA256,
			event.EvaluationDigestSHA256,
			event.RequestedDisclosureClass,
			event.PreviousState,
			event.State,
			event.NextState,
			event.Actor,
			event.CoordinatorEventID,
			event.ReasonCode,
			event.RequestID,
			event.Nonce,
			event.PayloadDigestSHA256,
			event.SignatureDigestSHA256,
			event.CreatedAt.Format(time.RFC3339Nano),
			event.RuntimeSource,
			event.CatalogMatchState,
			event.CatalogMatchReason,
			event.CatalogRowModelID,
			event.CatalogRowModelSHA256,
			event.CatalogReleaseID,
			event.CatalogCandidateSHA256,
			event.CatalogSignerKeyID,
			encodeModelAdmissionCatalogMembers(event.CatalogMembers),
			event.ArtifactFeedSHA256,
			event.ArtifactID,
			event.ArtifactHash,
			event.ArtifactHashAlgorithm,
			event.ArtifactFeedSignerKeyID,
			event.ArtifactCandidateCatalogSHA256,
			event.BoundMemberSource,
			int64(event.EvaluatedReleaseGeneration),
		); err != nil {
			return err
		}
		stored = event
		return invalidateSQLitePendingModelAdmissionDecisions(txCtx, conn, event.ProviderID, event.CandidateID)
	})
	return stored, replay, err
}

// scanSQLiteModelAdmissionReplay is the durable-store counterpart of the memory
// store's resolveModelAdmissionReplay. It checks request_id and nonce
// INDEPENDENTLY (not a single `OR ... LIMIT 1` row) and inspects EVERY supplied
// non-empty key before deciding, so a split-key event — one key bound to event
// A, the other to event B — never passes as a replay in either orientation:
// conflict if any supplied key is bound to a different payload, or if two keys
// map to different stored events; matched only when every supplied key agrees on
// the same event and payload. The unique (provider_id, request_id) and
// (provider_id, nonce) indexes guarantee each query returns at most one row.
// Used by both provider and coordinator SQLite appends for parity with memory.
func scanSQLiteModelAdmissionReplay(ctx context.Context, conn *sql.Conn, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, bool, error) {
	var matched *ModelAdmissionEvent
	consider := func(existing ModelAdmissionEvent, found bool) bool {
		if !found {
			return false
		}
		if existing.PayloadDigestSHA256 != event.PayloadDigestSHA256 {
			return true
		}
		if matched == nil {
			bound := existing
			matched = &bound
		} else if matched.CoordinatorEventID != existing.CoordinatorEventID {
			return true
		}
		return false
	}
	if event.RequestID != "" {
		existing, found, err := scanModelAdmissionEvent(ctx, conn, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND request_id = ?
 LIMIT 1`), event.ProviderID, event.RequestID)
		if err != nil {
			return ModelAdmissionEvent{}, false, false, err
		}
		if consider(existing, found) {
			return ModelAdmissionEvent{}, false, true, nil
		}
	}
	if event.Nonce != "" {
		existing, found, err := scanModelAdmissionEvent(ctx, conn, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND nonce = ?
 LIMIT 1`), event.ProviderID, event.Nonce)
		if err != nil {
			return ModelAdmissionEvent{}, false, false, err
		}
		if consider(existing, found) {
			return ModelAdmissionEvent{}, false, true, nil
		}
	}
	if matched != nil {
		return *matched, true, false, nil
	}
	return ModelAdmissionEvent{}, false, false, nil
}

func (s *SQLiteModelAdmissionStore) appendCoordinatorModelAdmissionEvent(ctx context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	return s.appendCoordinatorModelAdmissionEventCAS(ctx, event, "", nil)
}

func (s *SQLiteModelAdmissionStore) appendCoordinatorModelAdmissionEventCAS(ctx context.Context, event ModelAdmissionEvent, expectedHead string, approval *PendingModelAdmissionApproval) (ModelAdmissionEvent, bool, error) {
	now := event.CreatedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	event.CreatedAt = now.UTC()
	var stored ModelAdmissionEvent
	var replay bool
	err := sqliteutil.Transact(ctx, s.db, func(txCtx context.Context, conn *sql.Conn) error {
		// Generate any missing replay keys up front (deterministic, state-
		// independent) so keyless decisions are also idempotent, then resolve the
		// replay before latest-state transition validation so an idempotent retry
		// stays state-order independent. Mirrors the memory store.
		event = fillCoordinatorModelAdmissionReplayKeys(event)
		replayed, matched, conflict, err := scanSQLiteModelAdmissionReplay(txCtx, conn, event)
		if err != nil {
			return err
		}
		if conflict {
			return errModelAdmissionReplayConflict
		}
		if matched {
			stored = replayed
			replay = true
			return nil
		}
		previous, found, err := scanModelAdmissionEvent(txCtx, conn, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND candidate_id = ?
 ORDER BY id DESC
 LIMIT 1`), event.ProviderID, event.CandidateID)
		if err != nil {
			return err
		}
		if !found || !sameModelAdmissionTuple(previous, event) {
			return errModelAdmissionReplayConflict
		}
		if expectedHead != "" && previous.CoordinatorEventID != expectedHead {
			return errModelAdmissionStaleHead
		}
		if !modelAdmissionCoordinatorTransitionAllowed(previous.State, event.State) {
			return errModelAdmissionReplayConflict
		}
		if modelAdmissionTransitionRequiresCatalogAuthority(event.State) && !modelAdmissionEventHasTrustedCatalogAuthority(event) {
			return errModelAdmissionReplayConflict
		}
		if modelAdmissionTransitionReasonRequired(previous.State, event.State) && strings.TrimSpace(event.ReasonCode) == "" {
			return errModelAdmissionReplayConflict
		}
		actor := modelAdmissionActorCoordinator
		if strings.HasPrefix(event.Actor, "operator:") {
			actor = event.Actor
		}
		event = prepareModelAdmissionTransition(event, previous.State, actor, event.State)
		if _, err := conn.ExecContext(txCtx, `
INSERT INTO model_admission_events(
    provider_id, candidate_id, served_model_ref, catalog_model_key,
    catalog_id, catalog_body_digest, catalog_signature_key_id,
    catalog_signature_pubkey_fingerprint, expected_catalog_model_hash,
    expected_catalog_model_hash_algorithm,
    discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
    previous_state, state, next_state, actor, coordinator_event_id,
    reason_code, request_id, nonce, payload_digest_sha256,
    signature_digest_sha256, created_at_utc,
    runtime_source, catalog_match_state, catalog_match_reason,
    catalog_row_model_id, catalog_row_model_sha256, catalog_release_id,
    catalog_candidate_sha256, catalog_signer_key_id, catalog_members_json,
    artifact_feed_sha256, artifact_id, artifact_hash, artifact_hash_algorithm,
    artifact_feed_signer_key_id, artifact_candidate_catalog_sha256,
    bound_member_source, evaluated_release_generation
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			event.ProviderID,
			event.CandidateID,
			event.ServedModelRef,
			event.CatalogModelKey,
			event.CatalogID,
			event.CatalogBodyDigest,
			event.CatalogSignatureKeyID,
			event.CatalogSignaturePubkeyFingerprint,
			event.ExpectedCatalogModelHash,
			event.ExpectedCatalogModelHashAlgorithm,
			event.DiscoveryDigestSHA256,
			event.EvaluationDigestSHA256,
			event.RequestedDisclosureClass,
			event.PreviousState,
			event.State,
			event.NextState,
			event.Actor,
			event.CoordinatorEventID,
			event.ReasonCode,
			event.RequestID,
			event.Nonce,
			event.PayloadDigestSHA256,
			event.SignatureDigestSHA256,
			event.CreatedAt.Format(time.RFC3339Nano),
			event.RuntimeSource,
			event.CatalogMatchState,
			event.CatalogMatchReason,
			event.CatalogRowModelID,
			event.CatalogRowModelSHA256,
			event.CatalogReleaseID,
			event.CatalogCandidateSHA256,
			event.CatalogSignerKeyID,
			encodeModelAdmissionCatalogMembers(event.CatalogMembers),
			event.ArtifactFeedSHA256,
			event.ArtifactID,
			event.ArtifactHash,
			event.ArtifactHashAlgorithm,
			event.ArtifactFeedSignerKeyID,
			event.ArtifactCandidateCatalogSHA256,
			event.BoundMemberSource,
			int64(event.EvaluatedReleaseGeneration),
		); err != nil {
			return err
		}
		stored = event
		if err := invalidateSQLitePendingModelAdmissionDecisions(txCtx, conn, event.ProviderID, event.CandidateID); err != nil {
			return err
		}
		if approval != nil {
			return consumeSQLitePendingModelAdmissionDecision(txCtx, conn, *approval, event)
		}
		return nil
	})
	return stored, replay, err
}

func (s *SQLiteModelAdmissionStore) LatestModelAdmissionStatus(ctx context.Context, providerID, candidateID string) (ModelAdmissionEvent, bool, error) {
	return scanModelAdmissionEvent(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND candidate_id = ?
 ORDER BY id DESC
 LIMIT 1`), providerID, candidateID)
}

func (s *SQLiteModelAdmissionStore) LatestModelAdmissionRouteStatus(ctx context.Context, providerID, servedModelRef, catalogModelKey string) (ModelAdmissionEvent, bool, error) {
	servedModelRef = strings.TrimSpace(servedModelRef)
	catalogModelKey = strings.ToLower(strings.TrimSpace(catalogModelKey))
	if servedModelRef == "" && catalogModelKey == "" {
		return scanModelAdmissionEvent(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ?
 ORDER BY id DESC
 LIMIT 1`), providerID)
	}
	if servedModelRef == "" {
		return scanModelAdmissionEvent(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND LOWER(catalog_model_key) = ?
 ORDER BY id DESC
 LIMIT 1`), providerID, catalogModelKey)
	}
	if catalogModelKey == "" {
		return scanModelAdmissionEvent(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND served_model_ref = ?
 ORDER BY id DESC
 LIMIT 1`), providerID, servedModelRef)
	}
	return scanModelAdmissionEvent(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND served_model_ref = ? AND LOWER(catalog_model_key) = ?
 ORDER BY id DESC
 LIMIT 1`), providerID, servedModelRef, catalogModelKey)
}

func (s *SQLiteModelAdmissionStore) SettlementCapableModelAdmissionStatusesForServedModel(ctx context.Context, providerID, servedModelRef string) ([]ModelAdmissionEvent, error) {
	servedModelRef = strings.TrimSpace(servedModelRef)
	rows, err := s.db.QueryContext(ctx, modelAdmissionEventSelect(`
  FROM model_admission_events e
  JOIN (
       SELECT MAX(id) AS latest_id
         FROM model_admission_events
        WHERE provider_id = ? AND served_model_ref = ?
        GROUP BY provider_id, candidate_id
  ) latest ON latest.latest_id = e.id
 WHERE e.state = 'settlement_capable'
 ORDER BY e.id DESC`), providerID, servedModelRef)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []ModelAdmissionEvent
	for rows.Next() {
		event, err := scanModelAdmissionEventRow(rows)
		if err != nil {
			return nil, err
		}
		if ModelAdmissionSettlementStateCandidate(event) {
			events = append(events, event)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return events, nil
}

// latestModelAdmissionRouteStatusFromEvents mirrors the SQLite store's
// `ORDER BY id DESC LIMIT 1` route-status semantics: it walks the append-ordered
// event log from newest to oldest and returns the LAST-APPENDED event matching
// the filter — not the greatest CreatedAt. This keeps memory/SQLite parity so a
// backdated demotion or withdrawal appended after a settlement_capable event is
// still treated as the latest route status in both stores (money-path
// regressions in buyer tests, which use the memory store, cannot hide behind a
// CreatedAt tie-break).
func latestModelAdmissionRouteStatusFromEvents(events []ModelAdmissionEvent, providerID, servedModelRef, catalogModelKey string) (ModelAdmissionEvent, bool, error) {
	servedModelRef = strings.TrimSpace(servedModelRef)
	catalogModelKey = strings.ToLower(strings.TrimSpace(catalogModelKey))
	for i := len(events) - 1; i >= 0; i-- {
		event := events[i]
		if event.ProviderID != providerID {
			continue
		}
		if servedModelRef != "" && event.ServedModelRef != servedModelRef {
			continue
		}
		if catalogModelKey != "" && strings.ToLower(strings.TrimSpace(event.CatalogModelKey)) != catalogModelKey {
			continue
		}
		return event, true, nil
	}
	return ModelAdmissionEvent{}, false, nil
}

type modelAdmissionQueryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

type modelAdmissionScanner interface {
	Scan(...any) error
}

func scanModelAdmissionEvent(ctx context.Context, q modelAdmissionQueryer, query string, args ...any) (ModelAdmissionEvent, bool, error) {
	event, err := scanModelAdmissionEventRow(q.QueryRowContext(ctx, query, args...))
	if err == sql.ErrNoRows {
		return ModelAdmissionEvent{}, false, nil
	}
	if err != nil {
		return ModelAdmissionEvent{}, false, err
	}
	return event, true, nil
}

func scanModelAdmissionEventRow(row modelAdmissionScanner) (ModelAdmissionEvent, error) {
	var event ModelAdmissionEvent
	var createdAt, membersJSON string
	var evaluatedGeneration int64
	err := row.Scan(
		&event.CoordinatorEventID,
		&event.Actor,
		&event.ProviderID,
		&event.CandidateID,
		&event.ServedModelRef,
		&event.CatalogModelKey,
		&event.CatalogID,
		&event.CatalogBodyDigest,
		&event.CatalogSignatureKeyID,
		&event.CatalogSignaturePubkeyFingerprint,
		&event.ExpectedCatalogModelHash,
		&event.ExpectedCatalogModelHashAlgorithm,
		&event.DiscoveryDigestSHA256,
		&event.EvaluationDigestSHA256,
		&event.RequestedDisclosureClass,
		&event.PreviousState,
		&event.State,
		&event.NextState,
		&event.ReasonCode,
		&event.RequestID,
		&event.Nonce,
		&event.PayloadDigestSHA256,
		&event.SignatureDigestSHA256,
		&createdAt,
		&event.RuntimeSource,
		&event.CatalogMatchState,
		&event.CatalogMatchReason,
		&event.CatalogRowModelID,
		&event.CatalogRowModelSHA256,
		&event.CatalogReleaseID,
		&event.CatalogCandidateSHA256,
		&event.CatalogSignerKeyID,
		&membersJSON,
		&event.ArtifactFeedSHA256,
		&event.ArtifactID,
		&event.ArtifactHash,
		&event.ArtifactHashAlgorithm,
		&event.ArtifactFeedSignerKeyID,
		&event.ArtifactCandidateCatalogSHA256,
		&event.BoundMemberSource,
		&evaluatedGeneration,
	)
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	members, err := decodeModelAdmissionCatalogMembers(membersJSON)
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	event.CatalogMembers = members
	event.EvaluatedReleaseGeneration = uint64(evaluatedGeneration)
	parsed, err := time.Parse(time.RFC3339Nano, createdAt)
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	event.CreatedAt = parsed.UTC()
	return event, nil
}

func modelAdmissionEventSelect(tail string) string {
	return `SELECT coordinator_event_id, actor, provider_id, candidate_id, served_model_ref, catalog_model_key,
       catalog_id, catalog_body_digest, catalog_signature_key_id, catalog_signature_pubkey_fingerprint,
       expected_catalog_model_hash, expected_catalog_model_hash_algorithm,
       discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
       previous_state, state, next_state, reason_code, request_id, nonce, payload_digest_sha256,
       signature_digest_sha256, created_at_utc,
       runtime_source, catalog_match_state, catalog_match_reason,
       catalog_row_model_id, catalog_row_model_sha256, catalog_release_id,
       catalog_candidate_sha256, catalog_signer_key_id, catalog_members_json,
       artifact_feed_sha256, artifact_id, artifact_hash, artifact_hash_algorithm,
       artifact_feed_signer_key_id, artifact_candidate_catalog_sha256,
       bound_member_source, evaluated_release_generation` + tail
}

func scanModelAdmissionEvents(ctx context.Context, q interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}, query string, args ...any) ([]ModelAdmissionEvent, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []ModelAdmissionEvent
	for rows.Next() {
		event, err := scanModelAdmissionEventRow(rows)
		if err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

func sortModelAdmissionEventsByCandidate(events []ModelAdmissionEvent) {
	sort.Slice(events, func(i, j int) bool {
		if events[i].ProviderID != events[j].ProviderID {
			return events[i].ProviderID < events[j].ProviderID
		}
		return events[i].CandidateID < events[j].CandidateID
	})
}

func modelAdmissionProviderTransitionAllowed(previousState, nextState string) bool {
	switch nextState {
	case modelAdmissionOfferSubmitted:
		switch previousState {
		case modelAdmissionNotOffered, "offer_rejected", modelAdmissionWithdrawn, modelAdmissionRevoked:
			return true
		default:
			return false
		}
	case modelAdmissionWithdrawn:
		return modelAdmissionAllowedNextState(previousState, modelAdmissionWithdrawn)
	default:
		return false
	}
}

func modelAdmissionCoordinatorTransitionAllowed(previousState, nextState string) bool {
	if nextState == modelAdmissionWithdrawn || nextState == modelAdmissionOfferSubmitted {
		return false
	}
	return modelAdmissionAllowedNextState(previousState, nextState)
}

func modelAdmissionAllowedNextState(previousState, nextState string) bool {
	for _, allowed := range modelAdmissionAllowedNextStates(previousState) {
		if allowed == nextState {
			return true
		}
	}
	return false
}

func modelAdmissionTransitionReasonRequired(previousState, nextState string) bool {
	switch nextState {
	case "offer_rejected", modelAdmissionWithdrawn, modelAdmissionRevoked:
		return true
	default:
		return modelAdmissionDemotionRequiresReason(ModelAdmissionEvent{
			PreviousState: previousState,
			State:         nextState,
		})
	}
}

func modelAdmissionTransitionRequiresCatalogAuthority(nextState string) bool {
	return nextState == "catalog_priced" || nextState == "settlement_capable"
}

func modelAdmissionEventHasTrustedCatalogAuthority(event ModelAdmissionEvent) bool {
	return strings.TrimSpace(event.CatalogModelKey) != "" &&
		strings.TrimSpace(event.CatalogID) != "" &&
		validModelAdmissionSHA256Hex(event.CatalogBodyDigest) &&
		strings.TrimSpace(event.CatalogSignatureKeyID) != "" &&
		validModelAdmissionReceiptKeyFingerprint(event.CatalogSignaturePubkeyFingerprint) &&
		validModelAdmissionSHA256Hex(event.ExpectedCatalogModelHash) &&
		modelidentity.CanonicalAlgorithm(event.ExpectedCatalogModelHashAlgorithm)
}

func sameModelAdmissionTuple(previous, next ModelAdmissionEvent) bool {
	// CandidateID + ServedModelRef are the stable candidate identity. The
	// catalog binding is dynamic (looked up from the signed catalog, which can
	// change between offers), so it is NOT part of the identity tuple — a fresh
	// re-offer (from offer_rejected/withdrawn/revoked, with refreshed evidence)
	// is allowed to carry a newly discovered or dropped catalog_model_key. It
	// stays a provider claim until verified against exact catalog-body evidence.
	return previous.CandidateID == next.CandidateID &&
		previous.ServedModelRef == next.ServedModelRef
}

func modelAdmissionEventWithPriorEvidence(event, previous ModelAdmissionEvent) ModelAdmissionEvent {
	event.DiscoveryDigestSHA256 = previous.DiscoveryDigestSHA256
	event.EvaluationDigestSHA256 = previous.EvaluationDigestSHA256
	event.RequestedDisclosureClass = previous.RequestedDisclosureClass
	return event
}

func modelAdmissionRequiresRefreshedEvidence(previousState string) bool {
	switch previousState {
	case "offer_rejected", "withdrawn", "revoked":
		return true
	default:
		return false
	}
}

func modelAdmissionEvidenceRefreshed(previous, next ModelAdmissionEvent) bool {
	return previous.DiscoveryDigestSHA256 != next.DiscoveryDigestSHA256 ||
		previous.EvaluationDigestSHA256 != next.EvaluationDigestSHA256
}

func prepareModelAdmissionTransition(event ModelAdmissionEvent, previousState, actor, nextState string) ModelAdmissionEvent {
	event.CatalogModelKey = strings.ToLower(strings.TrimSpace(event.CatalogModelKey))
	event.Actor = actor
	event.PreviousState = previousState
	event.State = nextState
	event.NextState = nextState
	sum := sha256.Sum256([]byte(strings.Join([]string{
		event.Actor,
		event.ProviderID,
		event.CandidateID,
		event.RequestID,
		event.Nonce,
		event.PreviousState,
		event.NextState,
		event.PayloadDigestSHA256,
		event.CatalogID,
		event.CatalogBodyDigest,
		event.CatalogSignatureKeyID,
		event.CatalogSignaturePubkeyFingerprint,
		event.ExpectedCatalogModelHash,
		event.ExpectedCatalogModelHashAlgorithm,
	}, "\x00")))
	event.CoordinatorEventID = hex.EncodeToString(sum[:])
	return event
}

// fillCoordinatorModelAdmissionReplayKeys derives stable replay keys for a
// coordinator decision that did not supply its own. The digest is built only
// from inputs intrinsic to the decision (identity tuple, target state, reason,
// payload digest) and deliberately excludes the current latest state and the
// event timestamp, so a retry of the same decision produces the same keys and
// resolves idempotently regardless of when it is retried or how far the
// admission has since advanced.
func fillCoordinatorModelAdmissionReplayKeys(event ModelAdmissionEvent) ModelAdmissionEvent {
	if event.RequestID != "" && event.Nonce != "" {
		return event
	}
	sum := sha256.Sum256([]byte(strings.Join([]string{
		event.ProviderID,
		event.CandidateID,
		event.ServedModelRef,
		event.CatalogModelKey,
		event.CatalogID,
		event.CatalogBodyDigest,
		event.CatalogSignatureKeyID,
		event.CatalogSignaturePubkeyFingerprint,
		event.ExpectedCatalogModelHash,
		event.ExpectedCatalogModelHashAlgorithm,
		event.State,
		event.ReasonCode,
		event.PayloadDigestSHA256,
	}, "\x00")))
	digest := hex.EncodeToString(sum[:32])
	if event.RequestID == "" {
		event.RequestID = "coordinator_" + event.State + "_" + digest[:32]
	}
	if event.Nonce == "" {
		event.Nonce = "coordinator_nonce_" + event.State + "_" + digest[:32]
	}
	return event
}

// modelAdmissionSyntheticProbeResult is the coordinator-side result of a
// bounded synthetic probe dispatched through the provider wire protocol.
type modelAdmissionSyntheticProbeResult struct {
	ProviderWireRequestID            string
	Passed                           bool
	TargetState                      string
	ExperimentalVisibilityAuthorized bool
	ReasonCode                       string
	CreatedAt                        time.Time
}

// modelAdmissionSandboxProbeDecision builds the coordinator decision that moves
// a submitted offer into the bounded probe-only state. It does not imply buyer
// routing, catalog pricing, or settlement eligibility.
func modelAdmissionSandboxProbeDecision(current ModelAdmissionEvent, reasonCode string, now time.Time) (ModelAdmissionEvent, bool) {
	reasonCode = strings.TrimSpace(reasonCode)
	if current.State != modelAdmissionOfferSubmitted || reasonCode == "" {
		return ModelAdmissionEvent{}, false
	}
	return modelAdmissionCoordinatorDecisionFromCurrent(current, "sandbox_probe_only", reasonCode, "macprovider.model_admission.sandbox_probe_decision.v1", "", now), true
}

// modelAdmissionSyntheticProbeDecision builds a non-settlement coordinator
// decision from a probe result. Positive probe outcomes can only admit the
// candidate to explicit non-settlement visibility/routing states; failed probes
// revoke the admission with a reason. Catalog-priced and settlement-capable
// states remain owned by the trusted catalog and receipt paths, not probes.
func modelAdmissionSyntheticProbeDecision(current ModelAdmissionEvent, result modelAdmissionSyntheticProbeResult) (ModelAdmissionEvent, bool) {
	reasonCode := strings.TrimSpace(result.ReasonCode)
	wireRequestID := strings.TrimSpace(result.ProviderWireRequestID)
	if current.State != "sandbox_probe_only" || reasonCode == "" || !validModelAdmissionToken(wireRequestID) {
		return ModelAdmissionEvent{}, false
	}
	targetState := modelAdmissionRevoked
	if result.Passed {
		targetState = strings.TrimSpace(result.TargetState)
		switch targetState {
		case "network_visible_unpriced":
			if !result.ExperimentalVisibilityAuthorized {
				return ModelAdmissionEvent{}, false
			}
		case "network_admitted_unsettled":
		default:
			return ModelAdmissionEvent{}, false
		}
	}
	return modelAdmissionCoordinatorDecisionFromCurrent(current, targetState, reasonCode, "macprovider.model_admission.synthetic_probe_decision.v1", wireRequestID, result.CreatedAt), true
}

func modelAdmissionCoordinatorDecisionFromCurrent(current ModelAdmissionEvent, targetState, reasonCode, domain, evidence string, now time.Time) ModelAdmissionEvent {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	reasonCode = strings.TrimSpace(reasonCode)
	targetState = strings.TrimSpace(targetState)
	sum := sha256.Sum256([]byte(strings.Join([]string{
		domain,
		current.ProviderID,
		current.CandidateID,
		current.ServedModelRef,
		current.CatalogModelKey,
		current.DiscoveryDigestSHA256,
		current.EvaluationDigestSHA256,
		current.RequestedDisclosureClass,
		current.State,
		current.CoordinatorEventID,
		targetState,
		reasonCode,
		evidence,
	}, "\x00")))
	digest := hex.EncodeToString(sum[:])
	event := current
	event.State = targetState
	event.ReasonCode = reasonCode
	event.RequestID = "coordinator_" + targetState + "_" + digest[:32]
	event.Nonce = "coordinator_nonce_" + targetState + "_" + digest[:32]
	event.PayloadDigestSHA256 = digest
	event.SignatureDigestSHA256 = ""
	event.CreatedAt = now.UTC()
	event.CoordinatorEventID = ""
	event.Actor = ""
	event.PreviousState = ""
	event.NextState = ""
	return event
}

func ModelAdmissionSettlementStateCandidate(event ModelAdmissionEvent) bool {
	return event.State == "settlement_capable" &&
		event.ProviderID != "" &&
		event.CandidateID != "" &&
		event.ServedModelRef != "" &&
		event.CatalogModelKey != "" &&
		event.CoordinatorEventID != ""
}

type ModelAdmissionPaidRoutingPredicate struct {
	ProviderID                        string
	CandidateID                       string
	ServedModelRef                    string
	CatalogModelKey                   string
	DiscoveryDigestSHA256             string
	EvaluationDigestSHA256            string
	CatalogID                         string
	CatalogBodyDigest                 string
	CatalogSignatureKeyID             string
	CatalogSignaturePubkeyFingerprint string
	ExpectedCatalogModelHash          string
	ExpectedCatalogModelHashAlgorithm string
	// SPEC-010 v1.7 R007(d) six values for a feed-derived binding (mirrors
	// ModelAdmissionSettlementPredicate so the two convert field-for-field).
	// The runtime-drift revocation path leaves them empty: admission events
	// carry no artifact evidence (the route snapshot does), and a member
	// change within a session is a heartbeat MISMATCH (pool.pinArtifactSession,
	// R007(b) session authority), not a revocation.
	ArtifactFeedSHA256             string
	ArtifactID                     string
	ArtifactHash                   string
	ArtifactHashAlgorithm          string
	ArtifactFeedSignerKeyID        string
	ArtifactCandidateCatalogSHA256 string
}

func ModelAdmissionDefaultPaidRoutingEligible(event ModelAdmissionEvent, predicate ModelAdmissionPaidRoutingPredicate) bool {
	_, ok := ModelAdmissionSettlementBindingForRouteSnapshot(event, ModelAdmissionSettlementPredicate(predicate))
	return ok
}

type ModelAdmissionSettlementPredicate struct {
	ProviderID                        string
	CandidateID                       string
	ServedModelRef                    string
	CatalogModelKey                   string
	DiscoveryDigestSHA256             string
	EvaluationDigestSHA256            string
	CatalogID                         string
	CatalogBodyDigest                 string
	CatalogSignatureKeyID             string
	CatalogSignaturePubkeyFingerprint string
	ExpectedCatalogModelHash          string
	ExpectedCatalogModelHashAlgorithm string
	// SPEC-010 v1.7 R007(d) six values for a feed-derived binding.
	ArtifactFeedSHA256             string
	ArtifactID                     string
	ArtifactHash                   string
	ArtifactHashAlgorithm          string
	ArtifactFeedSignerKeyID        string
	ArtifactCandidateCatalogSHA256 string
}

// ArtifactDerived reports whether the predicate references an artifact-feed
// member (any of the six values present).
func (p ModelAdmissionSettlementPredicate) ArtifactDerived() bool {
	return p.ArtifactID != "" || p.ArtifactFeedSHA256 != "" || p.ArtifactHash != "" ||
		p.ArtifactHashAlgorithm != "" || p.ArtifactFeedSignerKeyID != "" || p.ArtifactCandidateCatalogSHA256 != ""
}

// artifactEvidenceComplete is the all-six-or-none rule, with the member's
// pair equal to the expected pair and the digests well-formed.
func (p ModelAdmissionSettlementPredicate) artifactEvidenceComplete() bool {
	return validModelAdmissionSHA256Hex(p.ArtifactFeedSHA256) &&
		strings.TrimSpace(p.ArtifactID) != "" &&
		validModelAdmissionSHA256Hex(p.ArtifactHash) &&
		modelidentity.CanonicalAlgorithm(p.ArtifactHashAlgorithm) &&
		strings.TrimSpace(p.ArtifactFeedSignerKeyID) != "" &&
		validModelAdmissionSHA256Hex(p.ArtifactCandidateCatalogSHA256) &&
		p.ArtifactHash == p.ExpectedCatalogModelHash &&
		p.ArtifactHashAlgorithm == p.ExpectedCatalogModelHashAlgorithm
}

type ModelAdmissionSettlementBinding struct {
	CandidateID            string
	CoordinatorEventID     string
	ServedModelRef         string
	CatalogModelKey        string
	DiscoveryDigestSHA256  string
	EvaluationDigestSHA256 string
	// SPEC-010 v1.7 R007(d) / SPEC-047-R003 six values, set only for a
	// feed-derived binding (the feed's primary entry included; a primary
	// identity bound directly through the signed candidate row carries none).
	ArtifactFeedSHA256             string
	ArtifactID                     string
	ArtifactHash                   string
	ArtifactHashAlgorithm          string
	ArtifactFeedSignerKeyID        string
	ArtifactCandidateCatalogSHA256 string
}

// ArtifactDerived reports whether the binding references an artifact-feed
// member and therefore must carry all six values.
func (b ModelAdmissionSettlementBinding) ArtifactDerived() bool { return b.ArtifactID != "" }

func ModelAdmissionSettlementBindingForRouteSnapshot(event ModelAdmissionEvent, predicate ModelAdmissionSettlementPredicate) (ModelAdmissionSettlementBinding, bool) {
	if !ModelAdmissionSettlementStateCandidate(event) {
		return ModelAdmissionSettlementBinding{}, false
	}
	if event.ProviderID != predicate.ProviderID ||
		event.CandidateID != predicate.CandidateID ||
		event.ServedModelRef != predicate.ServedModelRef ||
		event.CatalogModelKey != predicate.CatalogModelKey ||
		event.DiscoveryDigestSHA256 != predicate.DiscoveryDigestSHA256 ||
		event.EvaluationDigestSHA256 != predicate.EvaluationDigestSHA256 ||
		event.CatalogID != predicate.CatalogID ||
		event.CatalogBodyDigest != predicate.CatalogBodyDigest ||
		event.CatalogSignatureKeyID != predicate.CatalogSignatureKeyID ||
		event.CatalogSignaturePubkeyFingerprint != predicate.CatalogSignaturePubkeyFingerprint ||
		event.ExpectedCatalogModelHash != predicate.ExpectedCatalogModelHash ||
		event.ExpectedCatalogModelHashAlgorithm != predicate.ExpectedCatalogModelHashAlgorithm {
		return ModelAdmissionSettlementBinding{}, false
	}
	if !modelidentity.CanonicalAlgorithm(predicate.ExpectedCatalogModelHashAlgorithm) {
		return ModelAdmissionSettlementBinding{}, false
	}
	// SPEC-010-R007(d) / SPEC-047-R003: a feed-derived binding carries all six
	// artifact values; a partial record fails closed, and a GGUF expected
	// identity (never a row identity) with no evidence at all fails closed too.
	if (predicate.ArtifactDerived() || predicate.ExpectedCatalogModelHashAlgorithm == modelidentity.GGUFFileV1) &&
		!predicate.artifactEvidenceComplete() {
		return ModelAdmissionSettlementBinding{}, false
	}
	if !validModelAdmissionSHA256Hex(event.CoordinatorEventID) ||
		!validModelAdmissionSHA256Hex(predicate.DiscoveryDigestSHA256) ||
		!validModelAdmissionSHA256Hex(predicate.EvaluationDigestSHA256) ||
		!validModelAdmissionSHA256Hex(predicate.CatalogBodyDigest) ||
		!validModelAdmissionSHA256Hex(predicate.ExpectedCatalogModelHash) {
		return ModelAdmissionSettlementBinding{}, false
	}
	if strings.TrimSpace(predicate.CatalogID) == "" ||
		strings.TrimSpace(predicate.CatalogSignatureKeyID) == "" ||
		!validModelAdmissionReceiptKeyFingerprint(predicate.CatalogSignaturePubkeyFingerprint) {
		return ModelAdmissionSettlementBinding{}, false
	}
	return ModelAdmissionSettlementBinding{
		CandidateID:                    event.CandidateID,
		CoordinatorEventID:             event.CoordinatorEventID,
		ServedModelRef:                 event.ServedModelRef,
		CatalogModelKey:                event.CatalogModelKey,
		DiscoveryDigestSHA256:          event.DiscoveryDigestSHA256,
		EvaluationDigestSHA256:         event.EvaluationDigestSHA256,
		ArtifactFeedSHA256:             predicate.ArtifactFeedSHA256,
		ArtifactID:                     predicate.ArtifactID,
		ArtifactHash:                   predicate.ArtifactHash,
		ArtifactHashAlgorithm:          predicate.ArtifactHashAlgorithm,
		ArtifactFeedSignerKeyID:        predicate.ArtifactFeedSignerKeyID,
		ArtifactCandidateCatalogSHA256: predicate.ArtifactCandidateCatalogSHA256,
	}, true
}

func ModelAdmissionRevocationForRuntimeDrift(current ModelAdmissionEvent, predicate ModelAdmissionPaidRoutingPredicate, reasonCode string, now time.Time) (ModelAdmissionEvent, bool) {
	// Runtime-drift revocation only applies to a settlement-capable candidate —
	// the only state that could ever have been paid-routing eligible. For every
	// other state (offer_submitted, catalog_priced, and terminal withdrawn/
	// revoked) there is nothing to revoke: manufacturing a `revoked` event would
	// either be spurious or be rejected by the store's transition guard. Keeping
	// this decision here avoids pushing state-specific knowledge into callers.
	if !ModelAdmissionSettlementStateCandidate(current) {
		return ModelAdmissionEvent{}, false
	}
	if modelAdmissionRuntimePredicateMatches(current, predicate) {
		return ModelAdmissionEvent{}, false
	}
	reasonCode = strings.TrimSpace(reasonCode)
	if reasonCode == "" {
		return ModelAdmissionEvent{}, false
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	sum := sha256.Sum256([]byte(strings.Join([]string{
		current.ProviderID,
		current.CandidateID,
		current.State,
		predicate.ProviderID,
		predicate.CandidateID,
		predicate.ServedModelRef,
		predicate.CatalogModelKey,
		predicate.DiscoveryDigestSHA256,
		predicate.EvaluationDigestSHA256,
		predicate.CatalogID,
		predicate.CatalogBodyDigest,
		predicate.CatalogSignatureKeyID,
		predicate.CatalogSignaturePubkeyFingerprint,
		predicate.ExpectedCatalogModelHash,
		predicate.ExpectedCatalogModelHashAlgorithm,
		reasonCode,
		now.UTC().Format(time.RFC3339Nano),
	}, "\x00")))
	digest := hex.EncodeToString(sum[:])
	event := current
	event.State = modelAdmissionRevoked
	event.ReasonCode = reasonCode
	event.RequestID = "coordinator_revoke_" + digest[:32]
	event.Nonce = "coordinator_revoke_nonce_" + digest[:32]
	event.PayloadDigestSHA256 = digest
	event.SignatureDigestSHA256 = ""
	event.CreatedAt = now.UTC()
	return event, true
}

func modelAdmissionRuntimePredicateMatches(event ModelAdmissionEvent, predicate ModelAdmissionPaidRoutingPredicate) bool {
	return event.ProviderID == predicate.ProviderID &&
		event.CandidateID == predicate.CandidateID &&
		event.ServedModelRef == predicate.ServedModelRef &&
		event.CatalogModelKey == predicate.CatalogModelKey &&
		event.DiscoveryDigestSHA256 == predicate.DiscoveryDigestSHA256 &&
		event.EvaluationDigestSHA256 == predicate.EvaluationDigestSHA256 &&
		event.CatalogID == predicate.CatalogID &&
		event.CatalogBodyDigest == predicate.CatalogBodyDigest &&
		event.CatalogSignatureKeyID == predicate.CatalogSignatureKeyID &&
		event.CatalogSignaturePubkeyFingerprint == predicate.CatalogSignaturePubkeyFingerprint &&
		event.ExpectedCatalogModelHash == predicate.ExpectedCatalogModelHash &&
		event.ExpectedCatalogModelHashAlgorithm == predicate.ExpectedCatalogModelHashAlgorithm
}

func validModelAdmissionReceiptKeyFingerprint(value string) bool {
	const prefix = "ed25519-sha256:"
	return strings.HasPrefix(value, prefix) && validModelAdmissionSHA256Hex(strings.TrimPrefix(value, prefix))
}

func (s *Server) handleProviderModelAdmissionOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providerID, ok := s.authenticateProviderReadOnly(w, r)
	if !ok {
		return
	}
	// #1248 offer-submit disablement: reject new submissions before any
	// parsing or state append. Status readback and withdrawals stay live so
	// disabling submissions never loses or deletes provider state.
	if s.modelAdmissionSubmitDisabled {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError(modelAdmissionSubmissionsDisabledCode, "model admission offer submissions are disabled"))
		return
	}
	if !s.allowModelAdmissionAttempt(providerID) {
		writeJSON(w, http.StatusTooManyRequests, modelAdmissionError("rate_limited", "model admission offer rejected"))
		return
	}
	var body modelAdmissionOfferSubmitRequest
	r.Body = http.MaxBytesReader(w, r.Body, modelAdmissionMaxBodyBytes+1)
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_json", "invalid model admission offer package"))
		return
	}
	event, err := s.verifyModelAdmissionOffer(r.Context(), providerID, body)
	if err != nil {
		status := http.StatusBadRequest
		code := "invalid_offer"
		switch {
		case errors.Is(err, errModelAdmissionRateLimited):
			status, code = http.StatusTooManyRequests, "rate_limited"
		case errors.Is(err, errModelAdmissionCapExceeded):
			status, code = http.StatusTooManyRequests, "candidate_cap_exceeded"
		case errors.Is(err, errModelAdmissionReplayConflict):
			status, code = http.StatusConflict, "replay_conflict"
		case errors.Is(err, errModelAdmissionUnauthorized):
			status, code = http.StatusUnauthorized, "unauthorized"
		}
		writeJSON(w, status, modelAdmissionError(code, "model admission offer rejected"))
		return
	}
	// SPEC-047-R001 v0.1.5: the coordinator's offer-time catalog match is the
	// one authority for the candidate's catalog identity; the append, like
	// every append origin, holds the provider's section through the binding
	// refresh.
	event = s.applyModelAdmissionOfferCatalogMatch(event, body)
	stored, replay, err := s.appendModelAdmissionEventInSection(r.Context(), providerID, func(ctx context.Context) (ModelAdmissionEvent, bool, error) {
		return s.modelAdmissions.AppendModelAdmissionOffer(ctx, event)
	})
	if err != nil {
		status := http.StatusInternalServerError
		code := "model_admission_store_error"
		switch {
		case errors.Is(err, errModelAdmissionRateLimited):
			status, code = http.StatusTooManyRequests, "rate_limited"
		case errors.Is(err, errModelAdmissionCapExceeded):
			status, code = http.StatusTooManyRequests, "candidate_cap_exceeded"
		case errors.Is(err, errModelAdmissionReplayConflict):
			status, code = http.StatusConflict, "replay_conflict"
		}
		writeJSON(w, status, modelAdmissionError(code, "model admission offer rejected"))
		return
	}
	probeCtx, cancel := modelAdmissionOfferProbeContext(r.Context())
	defer cancel()
	stored = s.maybeRunModelAdmissionSyntheticProbeForOffer(probeCtx, stored, replay)
	writeJSON(w, http.StatusOK, s.modelAdmissionStatusResponseFromEvent(stored, replay))
}

func (s *Server) handleProviderModelAdmissionWithdrawal(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providerID, ok := s.authenticateProviderReadOnly(w, r)
	if !ok {
		return
	}
	if !s.allowModelAdmissionAttempt(providerID) {
		writeJSON(w, http.StatusTooManyRequests, modelAdmissionError("rate_limited", "model admission withdrawal rejected"))
		return
	}
	var body modelAdmissionWithdrawRequest
	r.Body = http.MaxBytesReader(w, r.Body, modelAdmissionMaxBodyBytes+1)
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_json", "invalid model admission withdrawal package"))
		return
	}
	event, err := s.verifyModelAdmissionWithdrawal(r.Context(), providerID, body)
	if err != nil {
		status := http.StatusBadRequest
		code := "invalid_withdrawal"
		switch {
		case errors.Is(err, errModelAdmissionRateLimited):
			status, code = http.StatusTooManyRequests, "rate_limited"
		case errors.Is(err, errModelAdmissionReplayConflict):
			status, code = http.StatusConflict, "replay_conflict"
		case errors.Is(err, errModelAdmissionUnauthorized):
			status, code = http.StatusUnauthorized, "unauthorized"
		}
		writeJSON(w, status, modelAdmissionError(code, "model admission withdrawal rejected"))
		return
	}
	stored, replay, err := s.appendModelAdmissionEventInSection(r.Context(), providerID, func(ctx context.Context) (ModelAdmissionEvent, bool, error) {
		return s.modelAdmissions.AppendModelAdmissionWithdrawal(ctx, event)
	})
	if err != nil {
		status := http.StatusInternalServerError
		code := "model_admission_store_error"
		switch {
		case errors.Is(err, errModelAdmissionRateLimited):
			status, code = http.StatusTooManyRequests, "rate_limited"
		case errors.Is(err, errModelAdmissionReplayConflict):
			status, code = http.StatusConflict, "replay_conflict"
		}
		writeJSON(w, status, modelAdmissionError(code, "model admission withdrawal rejected"))
		return
	}
	writeJSON(w, http.StatusOK, s.modelAdmissionWithdrawalResponseFromEvent(stored, replay))
}

func (s *Server) handleProviderModelAdmissionStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providerID, ok := s.authenticateProviderReadOnly(w, r)
	if !ok {
		return
	}
	candidateID := strings.TrimSpace(r.URL.Query().Get("candidate_id"))
	if !validModelAdmissionCandidateID(candidateID) {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_candidate_id", "invalid model admission candidate_id"))
		return
	}
	event, found, err := s.modelAdmissions.LatestModelAdmissionStatus(r.Context(), providerID, candidateID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, modelAdmissionError("model_admission_store_error", "model admission status lookup failed"))
		return
	}
	if !found {
		event = ModelAdmissionEvent{
			ProviderID:  providerID,
			CandidateID: candidateID,
			State:       modelAdmissionNotOffered,
			NextState:   modelAdmissionNotOffered,
			ReasonCode:  "not_offered",
			CreatedAt:   s.now().UTC(),
		}
	}
	writeJSON(w, http.StatusOK, s.modelAdmissionStatusResponseFromEvent(event, false))
}

var errModelAdmissionUnauthorized = errors.New("model admission unauthorized")

func (s *Server) authenticateProviderReadOnly(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !s.cfg.Auth.RequireProviderTokens {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("provider_tokens_not_enabled", "provider tokens not enabled"))
		return "", false
	}
	if s.tokens == nil {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("provider_tokens_unavailable", "provider tokens unavailable"))
		return "", false
	}
	raw := bearerToken(r.Header.Get("Authorization"))
	if raw == "" {
		writeJSON(w, http.StatusUnauthorized, modelAdmissionError("unauthorized", "provider bearer token required"))
		return "", false
	}
	readOnlyTokens, ok := s.tokens.(computeIntegrityReadOnlyTokenValidator)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("provider_tokens_read_only_unavailable", "provider token read-only validation unavailable"))
		return "", false
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	providerID, valid, err := readOnlyTokens.ValidateTokenReadOnly(ctx, raw)
	if err != nil || !valid {
		writeJSON(w, http.StatusUnauthorized, modelAdmissionError("unauthorized", "provider bearer token required"))
		return "", false
	}
	return providerID, true
}

func (s *Server) verifyModelAdmissionOffer(ctx context.Context, authenticatedProviderID string, body modelAdmissionOfferSubmitRequest) (ModelAdmissionEvent, error) {
	if s.providerModelAdmissionSanctioned(authenticatedProviderID) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	if body.Schema != modelAdmissionOfferSubmitSchema {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid schema")
	}
	if body.SignatureDomain != modelAdmissionOfferDomain || body.ProviderID != authenticatedProviderID {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	if err := validateModelAdmissionPayload(body); err != nil {
		return ModelAdmissionEvent{}, err
	}
	if body.SignatureAlgorithm != "ed25519" {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid signature algorithm")
	}
	signature, err := base64.StdEncoding.DecodeString(body.ProviderSignature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid signature")
	}
	activePubkey, found, blocked := s.durableIdentitySignaturePubkey(ctx, authenticatedProviderID)
	if blocked || !found {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	pubkeyDigest := sha256.Sum256(activePubkey)
	if body.SigningKeyDigest != hex.EncodeToString(pubkeyDigest[:]) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	canonical, err := jcs.CanonicalJSON(body.canonicalMap())
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	if !ed25519.Verify(ed25519.PublicKey(activePubkey), canonical, signature) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	payloadDigest := sha256.Sum256(canonical)
	signatureDigest := sha256.Sum256(signature)
	signedAt, err := time.Parse(time.RFC3339Nano, body.Timestamp)
	if err != nil {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid timestamp")
	}
	now := s.now().UTC()
	if signedAt.Before(now.Add(-modelAdmissionMaxClockSkew)) || signedAt.After(now.Add(modelAdmissionMaxClockSkew)) {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid timestamp")
	}
	catalogModelKey := strings.ToLower(strings.TrimSpace(body.CatalogModelKey))
	return ModelAdmissionEvent{
		ProviderID:               body.ProviderID,
		CandidateID:              body.CandidateID,
		ServedModelRef:           body.ServedModelRef,
		CatalogModelKey:          catalogModelKey,
		DiscoveryDigestSHA256:    body.DiscoveryDigestSHA256,
		EvaluationDigestSHA256:   body.EvaluationDigestSHA256,
		RequestedDisclosureClass: body.RequestedDisclosureClass,
		State:                    modelAdmissionOfferSubmitted,
		ReasonCode:               "provider_offer_submitted",
		RequestID:                body.IdempotencyKey,
		Nonce:                    body.Nonce,
		PayloadDigestSHA256:      hex.EncodeToString(payloadDigest[:]),
		SignatureDigestSHA256:    hex.EncodeToString(signatureDigest[:]),
		CreatedAt:                now,
	}, nil
}

func (s *Server) verifyModelAdmissionWithdrawal(ctx context.Context, authenticatedProviderID string, body modelAdmissionWithdrawRequest) (ModelAdmissionEvent, error) {
	if s.providerModelAdmissionSanctioned(authenticatedProviderID) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	if body.Schema != modelAdmissionWithdrawRequestSchema {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid schema")
	}
	if body.SignatureDomain != modelAdmissionWithdrawDomain || body.ProviderID != authenticatedProviderID {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	if err := validateModelAdmissionWithdrawalPayload(body); err != nil {
		return ModelAdmissionEvent{}, err
	}
	if body.SignatureAlgorithm != "ed25519" {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid signature algorithm")
	}
	signature, err := base64.StdEncoding.DecodeString(body.ProviderSignature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid signature")
	}
	activePubkey, found, blocked := s.durableIdentitySignaturePubkey(ctx, authenticatedProviderID)
	if blocked || !found {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	pubkeyDigest := sha256.Sum256(activePubkey)
	if body.SigningKeyDigest != hex.EncodeToString(pubkeyDigest[:]) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	canonical, err := jcs.CanonicalJSON(body.canonicalMap())
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	if !ed25519.Verify(ed25519.PublicKey(activePubkey), canonical, signature) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	payloadDigest := sha256.Sum256(canonical)
	signatureDigest := sha256.Sum256(signature)
	signedAt, err := time.Parse(time.RFC3339Nano, body.Timestamp)
	if err != nil {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid timestamp")
	}
	now := s.now().UTC()
	if signedAt.Before(now.Add(-modelAdmissionMaxClockSkew)) || signedAt.After(now.Add(modelAdmissionMaxClockSkew)) {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid timestamp")
	}
	catalogModelKey := strings.ToLower(strings.TrimSpace(modelAdmissionNullableStringValue(body.CatalogModelKey.Value)))
	return ModelAdmissionEvent{
		ProviderID:            body.ProviderID,
		CandidateID:           body.CandidateID,
		ServedModelRef:        body.ServedModelRef,
		CatalogModelKey:       catalogModelKey,
		State:                 modelAdmissionWithdrawn,
		ReasonCode:            body.ReasonCode,
		RequestID:             body.IdempotencyKey,
		Nonce:                 body.Nonce,
		PayloadDigestSHA256:   hex.EncodeToString(payloadDigest[:]),
		SignatureDigestSHA256: hex.EncodeToString(signatureDigest[:]),
		CreatedAt:             now,
	}, nil
}

func (s *Server) providerModelAdmissionSanctioned(providerID string) bool {
	if s.admission != nil && s.admission.Rejected(providerID) {
		return true
	}
	if s.pool == nil {
		return false
	}
	for _, sanction := range s.pool.CanarySanctions() {
		if sanction.ProviderID == providerID && sanction.FailCount > 0 {
			return true
		}
	}
	return false
}

func (s *Server) allowModelAdmissionAttempt(providerID string) bool {
	now := s.now().UTC()
	s.modelAdmissionAttemptMu.Lock()
	defer s.modelAdmissionAttemptMu.Unlock()
	if s.modelAdmissionAttempts == nil {
		s.modelAdmissionAttempts = map[string][]time.Time{}
	}
	window := pruneModelAdmissionWindow(s.modelAdmissionAttempts[providerID], now)
	if len(window) >= modelAdmissionMaxEvents {
		s.modelAdmissionAttempts[providerID] = window
		return false
	}
	s.modelAdmissionAttempts[providerID] = append(window, now)
	return true
}

type modelAdmissionOfferSubmitRequest struct {
	Schema                   string                              `json:"schema"`
	SignatureDomain          string                              `json:"signature_domain"`
	ProviderID               string                              `json:"provider_id"`
	CandidateID              string                              `json:"candidate_id"`
	RuntimeSource            string                              `json:"runtime_source"`
	ServedModelRef           string                              `json:"served_model_ref"`
	CatalogModelKey          string                              `json:"catalog_model_key"`
	DiscoveryDigestSHA256    string                              `json:"discovery_digest_sha256"`
	EvaluationDigestSHA256   string                              `json:"evaluation_digest_sha256"`
	ArtifactHashes           map[string]string                   `json:"artifact_hashes"`
	AdvisoryCapabilities     *modelAdmissionAdvisoryCapabilities `json:"advisory_capabilities"`
	FitEvidenceSource        string                              `json:"fit_evidence_source"`
	LocalReadiness           string                              `json:"local_readiness"`
	RequestedDisclosureClass string                              `json:"requested_disclosure_class"`
	Timestamp                string                              `json:"timestamp"`
	Nonce                    string                              `json:"nonce"`
	IdempotencyKey           string                              `json:"idempotency_key"`
	SigningKeyDigest         string                              `json:"signing_key_digest"`
	SignatureAlgorithm       string                              `json:"signature_algorithm"`
	ProviderSignature        string                              `json:"provider_signature"`
	CLIVersion               string                              `json:"cli_version"`
}

type modelAdmissionWithdrawRequest struct {
	Schema             string                       `json:"schema"`
	GeneratedAt        string                       `json:"generated_at"`
	CLIVersion         string                       `json:"cli_version"`
	SignatureDomain    string                       `json:"signature_domain"`
	ProviderID         string                       `json:"provider_id"`
	CandidateID        string                       `json:"candidate_id"`
	ServedModelRef     string                       `json:"served_model_ref"`
	CatalogModelKey    modelAdmissionNullableString `json:"catalog_model_key"`
	IdempotencyKey     string                       `json:"idempotency_key"`
	Nonce              string                       `json:"nonce"`
	Timestamp          string                       `json:"timestamp"`
	ReasonCode         string                       `json:"reason_code"`
	SigningKeyDigest   string                       `json:"signing_key_digest"`
	SignatureAlgorithm string                       `json:"signature_algorithm"`
	ProviderSignature  string                       `json:"provider_signature"`
}

func (p modelAdmissionWithdrawRequest) canonicalMap() map[string]any {
	return map[string]any{
		"signature_domain":   p.SignatureDomain,
		"provider_id":        p.ProviderID,
		"candidate_id":       p.CandidateID,
		"served_model_ref":   p.ServedModelRef,
		"catalog_model_key":  modelAdmissionStringOrNull(p.CatalogModelKey.Value),
		"idempotency_key":    p.IdempotencyKey,
		"nonce":              p.Nonce,
		"timestamp":          p.Timestamp,
		"reason_code":        p.ReasonCode,
		"signing_key_digest": p.SigningKeyDigest,
		"cli_version":        p.CLIVersion,
	}
}

type modelAdmissionNullableString struct {
	Value   *string
	Present bool
}

func (v *modelAdmissionNullableString) UnmarshalJSON(data []byte) error {
	v.Present = true
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "null" {
		v.Value = nil
		return nil
	}
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	v.Value = &value
	return nil
}

func (p modelAdmissionOfferSubmitRequest) canonicalMap() map[string]any {
	return map[string]any{
		"signature_domain":           p.SignatureDomain,
		"provider_id":                p.ProviderID,
		"candidate_id":               p.CandidateID,
		"runtime_source":             p.RuntimeSource,
		"served_model_ref":           p.ServedModelRef,
		"catalog_model_key":          p.CatalogModelKey,
		"discovery_digest_sha256":    p.DiscoveryDigestSHA256,
		"evaluation_digest_sha256":   p.EvaluationDigestSHA256,
		"artifact_hashes":            modelAdmissionArtifactHashesCanonicalMap(p.ArtifactHashes),
		"advisory_capabilities":      p.AdvisoryCapabilities.canonicalMap(),
		"fit_evidence_source":        p.FitEvidenceSource,
		"local_readiness":            p.LocalReadiness,
		"requested_disclosure_class": p.RequestedDisclosureClass,
		"timestamp":                  p.Timestamp,
		"nonce":                      p.Nonce,
		"idempotency_key":            p.IdempotencyKey,
		"signing_key_digest":         p.SigningKeyDigest,
		"cli_version":                p.CLIVersion,
	}
}

type modelAdmissionAdvisoryCapabilities struct {
	ChatCompletions             *bool   `json:"chat_completions"`
	Streaming                   *bool   `json:"streaming"`
	ToolCallPassthrough         *bool   `json:"tool_call_passthrough"`
	StructuredOutputPassthrough *bool   `json:"structured_output_passthrough"`
	JSONMode                    *bool   `json:"json_mode"`
	UsageReporting              *bool   `json:"usage_reporting"`
	MaxContextTokens            *int    `json:"max_context_tokens"`
	Quantization                *string `json:"quantization"`
	Family                      *string `json:"family"`
	RuntimeVersion              *string `json:"runtime_version"`
}

func (c *modelAdmissionAdvisoryCapabilities) canonicalMap() map[string]any {
	if c == nil {
		return map[string]any{}
	}
	return map[string]any{
		"chat_completions":              modelAdmissionBoolOrNull(c.ChatCompletions),
		"streaming":                     modelAdmissionBoolOrNull(c.Streaming),
		"tool_call_passthrough":         modelAdmissionBoolOrNull(c.ToolCallPassthrough),
		"structured_output_passthrough": modelAdmissionBoolOrNull(c.StructuredOutputPassthrough),
		"json_mode":                     modelAdmissionBoolOrNull(c.JSONMode),
		"usage_reporting":               modelAdmissionBoolOrNull(c.UsageReporting),
		"max_context_tokens":            modelAdmissionIntOrNull(c.MaxContextTokens),
		"quantization":                  modelAdmissionStringOrNull(c.Quantization),
		"family":                        modelAdmissionStringOrNull(c.Family),
		"runtime_version":               modelAdmissionStringOrNull(c.RuntimeVersion),
	}
}

func modelAdmissionBoolOrNull(value *bool) any {
	if value == nil {
		return nil
	}
	return *value
}

func modelAdmissionIntOrNull(value *int) any {
	if value == nil {
		return nil
	}
	return *value
}

func modelAdmissionStringOrNull(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func (c *modelAdmissionAdvisoryCapabilities) validate() error {
	if c == nil {
		return fmt.Errorf("invalid model admission evidence")
	}
	if c.MaxContextTokens != nil && *c.MaxContextTokens < 0 {
		return fmt.Errorf("invalid model admission evidence")
	}
	for _, value := range []*string{c.Quantization, c.Family, c.RuntimeVersion} {
		if value != nil && (len(*value) > 128 || unsafeModelAdmissionMaterial(*value)) {
			return fmt.Errorf("invalid model admission evidence")
		}
	}
	return nil
}

func modelAdmissionArtifactHashesCanonicalMap(hashes map[string]string) map[string]any {
	canonical := make(map[string]any, len(hashes))
	for key, value := range hashes {
		canonical[key] = value
	}
	return canonical
}

func validateModelAdmissionPayload(payload modelAdmissionOfferSubmitRequest) error {
	if err := config.ValidateProviderID(payload.ProviderID); err != nil {
		return err
	}
	if !validModelAdmissionCandidateID(payload.CandidateID) {
		return fmt.Errorf("invalid candidate_id")
	}
	values := []string{
		payload.CatalogModelKey,
		payload.FitEvidenceSource,
		payload.LocalReadiness,
		payload.RequestedDisclosureClass,
		payload.Nonce,
		payload.IdempotencyKey,
		payload.SigningKeyDigest,
	}
	for _, value := range values {
		if unsafeModelAdmissionMaterial(value) {
			return fmt.Errorf("unsafe model admission material")
		}
	}
	if !validModelAdmissionServedModelRef(payload.ServedModelRef) {
		return fmt.Errorf("invalid served_model_ref")
	}
	if !validModelAdmissionRuntimeSource(payload.RuntimeSource) {
		return fmt.Errorf("invalid runtime_source")
	}
	if payload.CatalogModelKey != "" && len(payload.CatalogModelKey) > 128 {
		return fmt.Errorf("invalid catalog_model_key")
	}
	if payload.ArtifactHashes == nil || payload.AdvisoryCapabilities == nil {
		return fmt.Errorf("invalid model admission evidence")
	}
	if len(payload.ArtifactHashes) > 16 {
		return fmt.Errorf("invalid model admission evidence")
	}
	// `artifact_hashes` is keyed by the SPEC-010-R002 algorithm name
	// (`macprovider.snapshot-manifest.v1`, `macprovider.gguf-file.v1`): a
	// closed set, not a free token — the names carry dots.
	for key, value := range payload.ArtifactHashes {
		if !modelidentity.CanonicalAlgorithm(key) || !validModelAdmissionSHA256Hex(value) {
			return fmt.Errorf("invalid model admission evidence")
		}
	}
	if err := payload.AdvisoryCapabilities.validate(); err != nil {
		return err
	}
	if payload.FitEvidenceSource == "" || len(payload.FitEvidenceSource) > 64 ||
		payload.LocalReadiness == "" || len(payload.LocalReadiness) > 64 {
		return fmt.Errorf("invalid model admission evidence")
	}
	if payload.RequestedDisclosureClass != "non_earning_provider_asserted" &&
		payload.RequestedDisclosureClass != "catalog_binding_requested" {
		return fmt.Errorf("invalid requested_disclosure_class")
	}
	if !validModelAdmissionSHA256Hex(payload.DiscoveryDigestSHA256) {
		return fmt.Errorf("invalid discovery digest")
	}
	if payload.EvaluationDigestSHA256 != "" && !validModelAdmissionSHA256Hex(payload.EvaluationDigestSHA256) {
		return fmt.Errorf("invalid evaluation digest")
	}
	if !validModelAdmissionToken(payload.Nonce) || !validModelAdmissionToken(payload.IdempotencyKey) ||
		reservedModelAdmissionToken(payload.Nonce) || reservedModelAdmissionToken(payload.IdempotencyKey) {
		return fmt.Errorf("invalid replay key")
	}
	if !validModelAdmissionSHA256Hex(payload.SigningKeyDigest) {
		return fmt.Errorf("invalid signing key digest")
	}
	if !validModelAdmissionCLIVersion(payload.CLIVersion) {
		return fmt.Errorf("invalid cli_version")
	}
	if _, err := time.Parse(time.RFC3339Nano, payload.Timestamp); err != nil {
		return fmt.Errorf("invalid timestamp")
	}
	return nil
}

func validateModelAdmissionWithdrawalPayload(payload modelAdmissionWithdrawRequest) error {
	if err := config.ValidateProviderID(payload.ProviderID); err != nil {
		return err
	}
	if !validModelAdmissionCandidateID(payload.CandidateID) {
		return fmt.Errorf("invalid candidate_id")
	}
	values := []string{
		payload.Nonce,
		payload.IdempotencyKey,
		payload.ReasonCode,
		payload.SigningKeyDigest,
	}
	for _, value := range values {
		if unsafeModelAdmissionMaterial(value) {
			return fmt.Errorf("unsafe model admission material")
		}
	}
	if !validModelAdmissionServedModelRef(payload.ServedModelRef) {
		return fmt.Errorf("invalid served_model_ref")
	}
	if !payload.CatalogModelKey.Present {
		return fmt.Errorf("missing catalog_model_key")
	}
	if payload.CatalogModelKey.Value != nil && (len(*payload.CatalogModelKey.Value) > 128 || unsafeModelAdmissionMaterial(*payload.CatalogModelKey.Value)) {
		return fmt.Errorf("invalid catalog_model_key")
	}
	if !validModelAdmissionWithdrawReason(payload.ReasonCode) {
		return fmt.Errorf("invalid reason_code")
	}
	if !validModelAdmissionToken(payload.Nonce) || !validModelAdmissionToken(payload.IdempotencyKey) ||
		reservedModelAdmissionToken(payload.Nonce) || reservedModelAdmissionToken(payload.IdempotencyKey) {
		return fmt.Errorf("invalid replay key")
	}
	if !validModelAdmissionSHA256Hex(payload.SigningKeyDigest) {
		return fmt.Errorf("invalid signing key digest")
	}
	if !validModelAdmissionCLIVersion(payload.CLIVersion) {
		return fmt.Errorf("invalid cli_version")
	}
	if _, err := time.Parse(time.RFC3339Nano, payload.GeneratedAt); err != nil {
		return fmt.Errorf("invalid generated_at")
	}
	if _, err := time.Parse(time.RFC3339Nano, payload.Timestamp); err != nil {
		return fmt.Errorf("invalid timestamp")
	}
	return nil
}

func (s *Server) modelAdmissionStatusResponseFromEvent(event ModelAdmissionEvent, _ bool) map[string]any {
	return map[string]any{
		"schema":                 modelAdmissionStatusSchema,
		"generated_at":           s.now().UTC().Format(time.RFC3339Nano),
		"cli_version":            s.version,
		"provider_id":            event.ProviderID,
		"candidate_id":           event.CandidateID,
		"served_model_ref":       event.ServedModelRef,
		"catalog_model_key":      nullString(event.CatalogModelKey),
		"admission_state":        event.State,
		"admission_state_source": "coordinator",
		"coordinator_event_id":   nullString(event.CoordinatorEventID),
		"state_observed_at":      event.CreatedAt.UTC().Format(time.RFC3339Nano),
		"provider_guidance":      modelAdmissionProviderGuidance(event),
		"allowed_next_states":    modelAdmissionAllowedNextStates(event.State),
		"warnings":               []string{},
	}
}

func (s *Server) modelAdmissionWithdrawalResponseFromEvent(event ModelAdmissionEvent, _ bool) map[string]any {
	return map[string]any{
		"schema":                    modelAdmissionWithdrawResponseSchema,
		"generated_at":              s.now().UTC().Format(time.RFC3339Nano),
		"cli_version":               s.version,
		"provider_id":               event.ProviderID,
		"candidate_id":              event.CandidateID,
		"served_model_ref":          event.ServedModelRef,
		"catalog_model_key":         nullString(event.CatalogModelKey),
		"idempotency_key":           event.RequestID,
		"reason_code":               event.ReasonCode,
		"previous_admission_state":  event.PreviousState,
		"coordinator_event_id":      event.CoordinatorEventID,
		"accepted_at":               event.CreatedAt.UTC().Format(time.RFC3339Nano),
		"resulting_admission_state": event.State,
		"provider_guidance":         modelAdmissionProviderGuidance(event),
		"warnings":                  []string{},
	}
}

func modelAdmissionProviderGuidance(event ModelAdmissionEvent) map[string]any {
	nextAction := "wait_for_coordinator"
	stateMeaning := "byom.admission.not_earning"
	earningPath := "no_earning_path_in_v0_1"
	transitionReason := any(nil)
	switch event.State {
	case modelAdmissionNotOffered:
		nextAction = "submit_offer"
		stateMeaning = "byom.admission.not_offered"
		earningPath = "local_inventory_only"
	case modelAdmissionOfferSubmitted:
		nextAction = "wait_for_coordinator"
		earningPath = modelAdmissionNonSettlementEarningPath(event.CatalogModelKey)
	case "offer_rejected":
		nextAction = "revise_and_reoffer"
		transitionReason = event.ReasonCode
	case "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced":
		nextAction = "withdraw"
		earningPath = modelAdmissionNonSettlementEarningPath(event.CatalogModelKey)
		if modelAdmissionDemotionRequiresReason(event) {
			transitionReason = event.ReasonCode
		}
	case "settlement_capable":
		nextAction = "maintain_runtime"
		earningPath = "settlement_capable"
	case "withdrawn", "revoked":
		nextAction = "submit_offer"
		transitionReason = event.ReasonCode
	}
	return map[string]any{
		"state_label_key":        "byom.admission." + event.State,
		"state_meaning_key":      stateMeaning,
		"next_action":            nextAction,
		"transition_reason_code": transitionReason,
		"earning_path_class":     earningPath,
	}
}

// modelAdmissionNonSettlementEarningPath returns the honest v0.1 earning-path
// disclosure for a non-settlement admitted state: a catalog-matched candidate
// still has a catalog/receipt path, but a genuinely non-catalog candidate has
// NO earning path in v0.1 (SPEC-047-R004) and must not be shown otherwise.
func modelAdmissionNonSettlementEarningPath(catalogModelKey string) string {
	if catalogModelKey != "" {
		return "not_earning_yet_catalog_or_receipt_path_exists"
	}
	return "no_earning_path_in_v0_1"
}

func modelAdmissionAllowedNextStates(state string) []string {
	switch state {
	case modelAdmissionNotOffered, "withdrawn", "revoked":
		return []string{modelAdmissionOfferSubmitted}
	case "offer_rejected":
		return []string{modelAdmissionOfferSubmitted, "revoked"}
	case modelAdmissionOfferSubmitted:
		return []string{"offer_rejected", "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	case "sandbox_probe_only":
		return []string{"network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	case "network_visible_unpriced":
		return []string{"network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	case "network_admitted_unsettled":
		return []string{"catalog_priced", "settlement_capable", "withdrawn", "revoked"}
	case "catalog_priced":
		return []string{"network_admitted_unsettled", "settlement_capable", "withdrawn", "revoked"}
	case "settlement_capable":
		return []string{"network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	default:
		return []string{}
	}
}

func modelAdmissionError(code, message string) map[string]any {
	return map[string]any{"error": map[string]any{"code": code, "message": message}}
}

func pruneModelAdmissionWindow(window []time.Time, now time.Time) []time.Time {
	cutoff := now.Add(-time.Hour)
	kept := window[:0]
	for _, ts := range window {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	return kept
}

func validModelAdmissionCandidateID(value string) bool {
	return modelAdmissionCandidatePattern.MatchString(value)
}

// reservedModelAdmissionToken rejects provider-chosen replay keys that could
// occupy a coordinator- or operator-origin slot of the shared
// (provider_id, request_id) replay index: a provider must never be able to
// pre-empt its own drift revocation or an operator's decision.
func reservedModelAdmissionToken(value string) bool {
	return strings.HasPrefix(value, "coordinator_") || strings.HasPrefix(value, "operator_")
}

func validModelAdmissionToken(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			r == '-' || r == '_' {
			continue
		}
		return false
	}
	return true
}

func validModelAdmissionRuntimeSource(value string) bool {
	switch value {
	case "mlx_cache", "ollama_loopback":
		return true
	default:
		return false
	}
}

func validModelAdmissionWithdrawReason(value string) bool {
	switch value {
	case "provider_requested", "wrong_model", "runtime_unavailable", "identity_mismatch", "policy_uncertain", "other_operator_reason":
		return true
	default:
		return false
	}
}

func validModelAdmissionCLIVersion(value string) bool {
	return modelAdmissionCLIVersionPattern.MatchString(value)
}

func validModelAdmissionServedModelRef(value string) bool {
	if value == "" || !modelAdmissionServedRefPattern.MatchString(value) {
		return false
	}
	if unsafeModelAdmissionTextMaterial(value) {
		return false
	}
	lower := strings.ToLower(value)
	if strings.Contains(lower, "://") || strings.Contains(lower, "@") {
		return false
	}
	if strings.HasPrefix(lower, "ollama:") {
		return modelAdmissionRefSegmentsSafe(value[len("ollama:"):])
	}
	return modelAdmissionRefSegmentsSafe(value)
}

// modelAdmissionRefSegmentsSafe rejects a served-model reference whose ANY
// path segment looks like a network location (SPEC-047-R007 privacy). Every
// "/"-delimited segment is checked, not just the first, so endpoint material
// cannot hide after the leading segment (e.g. "model/inference:8080").
func modelAdmissionRefSegmentsSafe(name string) bool {
	if name == "" ||
		strings.HasPrefix(name, "/") ||
		strings.Contains(name, "//") ||
		strings.Contains(name, "../") ||
		strings.Contains(name, `..\`) {
		return false
	}
	for _, seg := range strings.Split(name, "/") {
		if seg == "" || looksLikeModelAdmissionNetworkLocation(seg) {
			return false
		}
	}
	return true
}

func modelAdmissionDemotionRequiresReason(event ModelAdmissionEvent) bool {
	switch event.PreviousState {
	case "settlement_capable":
		return event.State == "catalog_priced" || event.State == "network_admitted_unsettled"
	case "catalog_priced":
		return event.State == "network_admitted_unsettled"
	default:
		return false
	}
}

func validModelAdmissionSHA256Hex(value string) bool {
	if len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil && strings.ToLower(value) == value
}

func unsafeModelAdmissionMaterial(value string) bool {
	if unsafeModelAdmissionTextMaterial(value) {
		return true
	}
	if looksLikeModelAdmissionNetworkLocation(value) {
		return true
	}
	return false
}

func unsafeModelAdmissionTextMaterial(value string) bool {
	if value == "" {
		return false
	}
	lower := strings.ToLower(value)
	if strings.Contains(lower, "api_key") || strings.Contains(lower, "secret") ||
		strings.Contains(lower, "token=") || strings.Contains(lower, "authorization") {
		return true
	}
	if strings.ContainsAny(value, "\x00\r\n\t") {
		return true
	}
	if strings.ContainsAny(value, "<>\"'`;") {
		return true
	}
	if strings.HasPrefix(value, "/") || strings.HasPrefix(value, "~") ||
		strings.Contains(value, "../") || strings.Contains(value, `..\`) ||
		strings.Contains(value, `\`) {
		return true
	}
	if parsed, err := url.Parse(value); err == nil && parsed.Scheme != "" {
		switch strings.ToLower(parsed.Scheme) {
		case "http", "https", "ws", "wss", "file", "ssh", "sftp", "ftp":
			return true
		}
	}
	if strings.Contains(value, "://") {
		return true
	}
	return false
}

func looksLikeModelAdmissionNetworkLocation(value string) bool {
	trimmed := strings.Trim(strings.TrimSpace(value), "[]")
	lower := strings.ToLower(trimmed)
	if strings.HasSuffix(trimmed, ".") && strings.Contains(trimmed, ".") {
		return true
	}
	if strings.Contains(lower, "localhost") {
		return true
	}
	if host, port, err := net.SplitHostPort(value); err == nil {
		// A host:port shape is itself an endpoint signal when the port is
		// numeric, regardless of whether the host looks like a network location
		// (e.g. "inference:8080" must be rejected, not accepted).
		if _, perr := strconv.ParseUint(port, 10, 16); perr == nil {
			return true
		}
		return looksLikeModelAdmissionNetworkLocation(host)
	}
	if strings.HasPrefix(value, "[") && strings.Contains(value, "]:") {
		if host, _, err := net.SplitHostPort(value); err == nil {
			return looksLikeModelAdmissionNetworkLocation(host)
		}
	}
	if ip := net.ParseIP(trimmed); ip != nil {
		return true
	}
	if strings.HasPrefix(lower, "0x") {
		if n, err := strconv.ParseUint(strings.TrimPrefix(lower, "0x"), 16, 32); err == nil && n > 0 {
			return true
		}
	}
	if n, err := strconv.ParseUint(lower, 10, 32); err == nil && (n <= 65535 || n >= 0x01000000) {
		return true
	}
	if strings.Count(trimmed, ".") >= 1 {
		labels := strings.Split(trimmed, ".")
		allNumeric := true
		for _, label := range labels {
			if label == "" {
				return false
			}
			if _, err := strconv.ParseUint(label, 0, 8); err != nil {
				allNumeric = false
			}
		}
		// A DNS hostname ends in a pure-alpha TLD (com, co, tech, local...).
		// A model version token ends in an alphanumeric label (e.g.
		// "Llama-3.2-3B-Instruct-4bit"), which must NOT be treated as a host.
		if allNumeric || isPureAlphaTLD(labels[len(labels)-1]) {
			return true
		}
	}
	return false
}

func isPureAlphaTLD(label string) bool {
	if len(label) < 2 {
		return false
	}
	for _, r := range label {
		if (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') {
			return false
		}
	}
	return true
}

func nullString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func modelAdmissionNullableStringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
