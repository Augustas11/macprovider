package ws

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/jcs"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

// SPEC-047-R001 v0.1.5 operator decision path: the ONE production caller of
// the `coordinator admission policy` actor for operator-origin decisions,
// dual control on the money-path grant, the offer listing an operator
// decides on, and the route-time compare-and-insert guard (R003).

const (
	modelAdmissionDecisionRequestSchema = "model_admission_decision_request.v1"
	modelAdmissionApproveRequestSchema  = "model_admission_decision_approve_request.v1"
	modelAdmissionDecisionSchema        = "model_admission_decision.v1"
	modelAdmissionOfferListSchema       = "model_admission_offer_list.v1"
	modelAdmissionOfferListMemberCap    = 16
	// modelAdmissionOperatorRateCap bounds decision requests per operator
	// credential and source address per hour.
	modelAdmissionOperatorRateCap = 600
)

var (
	modelAdmissionOperatorProviderPattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)
	modelAdmissionOperatorReasonPattern   = regexp.MustCompile(`^operator_[a-z0-9_]{2,56}$`)
	modelAdmissionOperatorEventIDPattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	modelAdmissionIdempotencyKeyPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	modelAdmissionPendingIDPattern        = regexp.MustCompile(`^[0-9a-f]{32}$`)
	modelAdmissionOperatorActorPattern    = regexp.MustCompile(`^operator:[a-z0-9][a-z0-9_.-]{0,63}$`)
)

// modelAdmissionOperatorNextStates are the five operator-origin edges.
var modelAdmissionOperatorNextStates = map[string]struct{}{
	"network_visible_unpriced":   {},
	"network_admitted_unsettled": {},
	"catalog_priced":             {},
	"settlement_capable":         {},
	modelAdmissionRevoked:        {},
}

type modelAdmissionDecisionRequest struct {
	Schema                     string `json:"schema"`
	ProviderID                 string `json:"provider_id"`
	CandidateID                string `json:"candidate_id"`
	NextState                  string `json:"next_state"`
	ReasonCode                 string `json:"reason_code"`
	ExpectedCoordinatorEventID string `json:"expected_coordinator_event_id"`
	IdempotencyKey             string `json:"idempotency_key"`
}

func (r modelAdmissionDecisionRequest) validate() bool {
	_, edge := modelAdmissionOperatorNextStates[r.NextState]
	return r.Schema == modelAdmissionDecisionRequestSchema &&
		modelAdmissionOperatorProviderPattern.MatchString(r.ProviderID) &&
		validModelAdmissionCandidateID(r.CandidateID) &&
		edge &&
		modelAdmissionOperatorReasonPattern.MatchString(r.ReasonCode) &&
		modelAdmissionOperatorEventIDPattern.MatchString(r.ExpectedCoordinatorEventID) &&
		modelAdmissionIdempotencyKeyPattern.MatchString(r.IdempotencyKey)
}

func canonicalDigest(fields map[string]any) string {
	canonical, err := jcs.CanonicalJSON(fields)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:])
}

func (r modelAdmissionDecisionRequest) digest() string {
	return canonicalDigest(map[string]any{
		"schema": r.Schema, "provider_id": r.ProviderID, "candidate_id": r.CandidateID, "next_state": r.NextState,
		"reason_code": r.ReasonCode, "expected_coordinator_event_id": r.ExpectedCoordinatorEventID, "idempotency_key": r.IdempotencyKey,
	})
}

// requestID is the store replay key of an operator decision: the replay
// index is thereby keyed by (provider_id, candidate_id, idempotency_key).
func (r modelAdmissionDecisionRequest) requestID() string {
	// ':' is outside the provider `idempotency_key` grammar, so no
	// provider-chosen request id can ever occupy an operator's slot.
	return "operator_decision:" + r.CandidateID + ":" + r.IdempotencyKey
}

type modelAdmissionApproveRequest struct {
	Schema                     string `json:"schema"`
	ProviderID                 string `json:"provider_id"`
	CandidateID                string `json:"candidate_id"`
	PendingDecisionID          string `json:"pending_decision_id"`
	ExpectedCoordinatorEventID string `json:"expected_coordinator_event_id"`
	IdempotencyKey             string `json:"idempotency_key"`
}

func (r modelAdmissionApproveRequest) validate() bool {
	return r.Schema == modelAdmissionApproveRequestSchema &&
		modelAdmissionOperatorProviderPattern.MatchString(r.ProviderID) &&
		validModelAdmissionCandidateID(r.CandidateID) &&
		modelAdmissionPendingIDPattern.MatchString(r.PendingDecisionID) &&
		modelAdmissionOperatorEventIDPattern.MatchString(r.ExpectedCoordinatorEventID) &&
		modelAdmissionIdempotencyKeyPattern.MatchString(r.IdempotencyKey)
}

func (r modelAdmissionApproveRequest) digest() string {
	return canonicalDigest(map[string]any{
		"schema": r.Schema, "provider_id": r.ProviderID, "candidate_id": r.CandidateID, "pending_decision_id": r.PendingDecisionID,
		"expected_coordinator_event_id": r.ExpectedCoordinatorEventID, "idempotency_key": r.IdempotencyKey,
	})
}

// requestID keys approvals in their own namespace (pending_decision_id,
// idempotency_key).
func (r modelAdmissionApproveRequest) requestID() string {
	return "operator_approval:" + r.PendingDecisionID + ":" + r.IdempotencyKey
}

// modelAdmissionDecisionError is a closed-code failure of the decision path.
type modelAdmissionDecisionError struct {
	status int
	code   string
}

func (e *modelAdmissionDecisionError) Error() string { return e.code }

func decisionFail(status int, code string) error {
	return &modelAdmissionDecisionError{status: status, code: code}
}

func writeModelAdmissionDecisionError(w http.ResponseWriter, err error) {
	var failure *modelAdmissionDecisionError
	if errors.As(err, &failure) {
		writeJSON(w, failure.status, modelAdmissionError(failure.code, "model admission decision rejected"))
		return
	}
	writeJSON(w, http.StatusInternalServerError, modelAdmissionError("model_admission_store_error", "model admission decision failed"))
}

// ---- operator rate limiting (independent of every per-provider window)

type operatorRateLimiter struct {
	mu      sync.Mutex
	windows map[string][]time.Time
}

func (l *operatorRateLimiter) allow(key string, now time.Time, limit int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.windows == nil {
		l.windows = map[string][]time.Time{}
	}
	for k, w := range l.windows {
		if k != key && len(pruneModelAdmissionWindow(w, now)) == 0 {
			delete(l.windows, k)
		}
	}
	window := pruneModelAdmissionWindow(l.windows[key], now)
	if len(window) >= limit {
		l.windows[key] = window
		return false
	}
	l.windows[key] = append(window, now)
	return true
}

func (s *Server) allowModelAdmissionOperatorAttempt(actor string, r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return s.modelAdmissionOperatorLimiter.allow(actor+"|"+host, s.now(), modelAdmissionOperatorRateCap)
}

// authorizedModelAdmissionOperator authenticates the per-actor operator
// credential class (never the shared operator_key) and applies the operator
// rate window; it writes the closed error itself.
func (s *Server) authorizedModelAdmissionOperator(w http.ResponseWriter, r *http.Request) (string, bool) {
	actor, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok || !modelAdmissionOperatorActorPattern.MatchString(actor) {
		writeJSON(w, http.StatusUnauthorized, modelAdmissionError("invalid_operator_token", "unauthorized"))
		return "", false
	}
	if !s.allowModelAdmissionOperatorAttempt(actor, r) {
		writeJSON(w, http.StatusTooManyRequests, modelAdmissionError("rate_limited", "model admission operator rate limited"))
		return "", false
	}
	return actor, true
}

// operatorDualControlAvailable: dual control needs at least two entries
// that can actually act on this surface — normalized actor ids matching the
// SPEC-047 actor grammar, DISTINCT after normalization (`alice` and
// `operator:alice` are one actor), with non-empty, pairwise-distinct
// secrets (distinct ids sharing one secret are one principal). Entries that
// cannot authenticate here do not count.
func (s *Server) operatorDualControlAvailable() bool {
	actors := map[string]struct{}{}
	secrets := map[string]struct{}{}
	for actorID, secret := range s.cfg.Auth.OperatorKeys {
		actor := normalizedOperatorActor(actorID)
		if !modelAdmissionOperatorActorPattern.MatchString(actor) {
			continue
		}
		secret = strings.TrimSpace(secret)
		if secret == "" {
			return false
		}
		if _, dup := secrets[secret]; dup {
			return false
		}
		secrets[secret] = struct{}{}
		actors[actor] = struct{}{}
	}
	return len(actors) >= 2 && len(secrets) == len(actors)
}

// ---- decision response

type modelAdmissionDecisionOutcome struct {
	event    ModelAdmissionEvent
	pending  *PendingModelAdmissionDecision
	replayed bool
}

func (s *Server) modelAdmissionDecisionResponse(o modelAdmissionDecisionOutcome) map[string]any {
	resp := map[string]any{
		"schema":                   modelAdmissionDecisionSchema,
		"generated_at":             s.now().UTC().Format(time.RFC3339Nano),
		"provider_id":              o.event.ProviderID,
		"candidate_id":             o.event.CandidateID,
		"served_model_ref":         o.event.ServedModelRef,
		"catalog_model_key":        nullString(o.event.CatalogModelKey),
		"previous_admission_state": o.event.PreviousState,
		"admission_state":          o.event.State,
		"reason_code":              o.event.ReasonCode,
		"coordinator_event_id":     o.event.CoordinatorEventID,
		"accepted_at":              o.event.CreatedAt.UTC().Format(time.RFC3339Nano),
		"decided_by":               o.event.Actor,
		"replayed":                 o.replayed,
		"pending_decision_id":      nil,
		"bound_member":             nil,
	}
	if o.pending != nil {
		// Pending values (R001), answered from the RECORD so a replay returns
		// what the request originally produced whatever the head did since:
		// the unchanged state twice, the request's reason, the evaluated
		// head, the record's creation time, the requesting actor.
		resp["provider_id"] = o.pending.ProviderID
		resp["candidate_id"] = o.pending.CandidateID
		resp["served_model_ref"] = o.pending.ServedModelRef
		resp["catalog_model_key"] = nullString(o.pending.CatalogModelKey)
		resp["previous_admission_state"] = o.pending.AdmissionState
		resp["admission_state"] = o.pending.AdmissionState
		resp["reason_code"] = o.pending.ReasonCode
		resp["coordinator_event_id"] = o.pending.EvaluatedHead
		resp["accepted_at"] = o.pending.CreatedAt.UTC().Format(time.RFC3339Nano)
		resp["decided_by"] = o.pending.RequestedBy
		resp["pending_decision_id"] = o.pending.ID
		return resp
	}
	if o.event.State == "settlement_capable" && o.event.BoundMemberSource != "" {
		resp["bound_member"] = map[string]any{
			"source":         o.event.BoundMemberSource,
			"artifact_id":    nullString(o.event.ArtifactID),
			"hash_algorithm": o.event.ExpectedCatalogModelHashAlgorithm,
			"hash":           o.event.ExpectedCatalogModelHash,
		}
	}
	return resp
}

// ---- POST /admin/model-admission/decisions

func (s *Server) handleAdminModelAdmissionDecisions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "method not allowed"))
		return
	}
	actor, ok := s.authorizedModelAdmissionOperator(w, r)
	if !ok {
		return
	}
	if s.modelAdmissions == nil {
		writeJSON(w, http.StatusInternalServerError, modelAdmissionError("model_admission_store_error", "model admission store unavailable"))
		return
	}
	var body modelAdmissionDecisionRequest
	r.Body = http.MaxBytesReader(w, r.Body, modelAdmissionMaxBodyBytes+1)
	if err := decodeStrictJSON(r.Body, &body); err != nil || !body.validate() {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "invalid model admission decision request"))
		return
	}
	var (
		outcome modelAdmissionDecisionOutcome
		err     error
	)
	s.withProviderSection(body.ProviderID, func(section *providerSection) {
		outcome, err = s.applyModelAdmissionDecisionLocked(r.Context(), actor, body, section)
	})
	if err != nil {
		writeModelAdmissionDecisionError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, s.modelAdmissionDecisionResponse(outcome))
}

// applyModelAdmissionDecisionLocked executes the R001 precedence as one unit
// inside the provider's section: (1) idempotency, (2) head compare, (3)
// edge, (4) R003 preconditions, (5) release-generation re-compare + append —
// or, for settlement_capable, the pending record.
func (s *Server) applyModelAdmissionDecisionLocked(ctx context.Context, actor string, body modelAdmissionDecisionRequest, section *providerSection) (modelAdmissionDecisionOutcome, error) {
	digest := body.digest()
	requestID := body.requestID()
	// Lock order: section → registry → release. The live session is read
	// before the release read lock, which then spans the whole evaluation
	// (1)–(5) as ONE reader of ONE release snapshot.
	var provider pool.Provider
	hasSession := false
	if s.pool != nil {
		provider, hasSession = s.pool.Resolve(body.ProviderID, "")
	}
	var (
		outcome  modelAdmissionDecisionOutcome
		evalErr  error
		appended bool
	)
	s.withReleaseRead(func() {
		outcome, appended, evalErr = s.evaluateModelAdmissionDecisionLocked(ctx, actor, body, digest, requestID, provider, hasSession)
	})
	if evalErr != nil {
		return modelAdmissionDecisionOutcome{}, mapDecisionStoreError(evalErr)
	}
	if appended {
		stored := outcome.event
		s.afterModelAdmissionAppendLocked(ctx, body.ProviderID, section)
		s.log.Info().
			Str("admin_action", "model_admission_decision").
			Str("actor", actor).
			Str("provider_id", body.ProviderID).
			Str("candidate_id", body.CandidateID).
			Str("previous_state", stored.PreviousState).
			Str("admission_state", stored.State).
			Str("reason_code", stored.ReasonCode).
			Str("coordinator_event_id", stored.CoordinatorEventID).
			Msg("model admission operator decision appended")
	}
	return outcome, nil
}

// evaluateModelAdmissionDecisionLocked is precedence (1)–(5) under the
// section and the release read lock; appended reports a new event (the
// caller refreshes the binding after the read lock is released).
func (s *Server) evaluateModelAdmissionDecisionLocked(ctx context.Context, actor string, body modelAdmissionDecisionRequest, digest, requestID string, provider pool.Provider, hasSession bool) (modelAdmissionDecisionOutcome, bool, error) {
	// (1) idempotency: an identical request answers what it originally
	// produced — the appended event or the pending record — whatever the head.
	if prior, found, err := s.modelAdmissions.ModelAdmissionEventByRequestID(ctx, body.ProviderID, requestID); err != nil {
		return modelAdmissionDecisionOutcome{}, false, err
	} else if found {
		if prior.PayloadDigestSHA256 != digest || prior.CandidateID != body.CandidateID {
			return modelAdmissionDecisionOutcome{}, false, decisionFail(http.StatusConflict, "idempotency_conflict")
		}
		return modelAdmissionDecisionOutcome{event: prior, replayed: true}, false, nil
	}
	if pending, found, err := s.modelAdmissions.PendingModelAdmissionDecisionByRequest(ctx, body.ProviderID, body.CandidateID, requestID); err != nil {
		return modelAdmissionDecisionOutcome{}, false, err
	} else if found {
		if pending.RequestDigest != digest {
			return modelAdmissionDecisionOutcome{}, false, decisionFail(http.StatusConflict, "idempotency_conflict")
		}
		return modelAdmissionDecisionOutcome{pending: &pending, replayed: true}, false, nil
	}
	head, found, err := s.modelAdmissions.LatestModelAdmissionStatus(ctx, body.ProviderID, body.CandidateID)
	if err != nil {
		return modelAdmissionDecisionOutcome{}, false, err
	}
	if !found {
		return modelAdmissionDecisionOutcome{}, false, decisionFail(http.StatusNotFound, "no_offer")
	}
	// (2) head compare.
	if head.CoordinatorEventID != body.ExpectedCoordinatorEventID {
		return modelAdmissionDecisionOutcome{}, false, decisionFail(http.StatusConflict, "stale_head")
	}
	// (3) edge validation.
	if !modelAdmissionCoordinatorTransitionAllowed(head.State, body.NextState) {
		return modelAdmissionDecisionOutcome{}, false, decisionFail(http.StatusConflict, "invalid_transition")
	}
	decision := operatorDecisionFromHead(head, body.NextState, actor, body.ReasonCode, requestID, "operator_nonce_"+digest[:32], digest, s.now())
	generation := s.artifactIdentitySets.generationLocked()
	// (4) R003 preconditions, in their stated order, for the two
	// catalog-bound edges only.
	if modelAdmissionTransitionRequiresCatalogAuthority(body.NextState) {
		if err := s.bindDecisionToCatalogLocked(&decision, head, body.NextState == "settlement_capable", provider, hasSession); err != nil {
			return modelAdmissionDecisionOutcome{}, false, err
		}
	}
	decision.EvaluatedReleaseGeneration = generation
	if body.NextState == "settlement_capable" {
		// Dual control: the request appends nothing.
		if !s.operatorDualControlAvailable() {
			return modelAdmissionDecisionOutcome{}, false, decisionFail(http.StatusConflict, "dual_control_unavailable")
		}
		record := PendingModelAdmissionDecision{
			ID:              strings.ReplaceAll(s.newUUID(), "-", ""),
			ProviderID:      body.ProviderID,
			CandidateID:     body.CandidateID,
			NextState:       body.NextState,
			ReasonCode:      body.ReasonCode,
			RequestDigest:   digest,
			RequestID:       requestID,
			EvaluatedHead:   head.CoordinatorEventID,
			RequestedBy:     actor,
			CreatedAt:       s.now().UTC(),
			AdmissionState:  head.State,
			ServedModelRef:  head.ServedModelRef,
			CatalogModelKey: head.CatalogModelKey,
		}
		if !modelAdmissionPendingIDPattern.MatchString(record.ID) {
			return modelAdmissionDecisionOutcome{}, false, errors.New("generated pending_decision_id is invalid")
		}
		created, replay, err := s.modelAdmissions.CreatePendingModelAdmissionDecision(ctx, record)
		if err != nil {
			return modelAdmissionDecisionOutcome{}, false, err
		}
		return modelAdmissionDecisionOutcome{pending: &created, replayed: replay}, false, nil
	}
	// (5) release-generation re-compare (one read-lock hold spans (1)–(5),
	// so the generation cannot have moved) + append.
	stored, replayed, err := s.modelAdmissions.CASAppendModelAdmissionDecision(ctx, decision, head.CoordinatorEventID)
	if err != nil {
		return modelAdmissionDecisionOutcome{}, false, err
	}
	return modelAdmissionDecisionOutcome{event: stored, replayed: replayed}, !replayed, nil
}

// operatorDecisionFromHead is the operator-origin event before catalog
// binding: the head's candidate tuple and recorded match, the operator
// actor, the request's replay keys, no bound member.
func operatorDecisionFromHead(head ModelAdmissionEvent, nextState, actor, reason, requestID, nonce, digest string, now time.Time) ModelAdmissionEvent {
	decision := head
	decision.State = nextState
	decision.Actor = actor
	decision.ReasonCode = reason
	decision.RequestID = requestID
	decision.Nonce = nonce
	decision.PayloadDigestSHA256 = digest
	decision.SignatureDigestSHA256 = ""
	decision.CreatedAt = now.UTC()
	decision.CoordinatorEventID = ""
	decision.PreviousState = ""
	decision.NextState = ""
	decision.ArtifactFeedSHA256 = ""
	decision.ArtifactID = ""
	decision.ArtifactHash = ""
	decision.ArtifactHashAlgorithm = ""
	decision.ArtifactFeedSignerKeyID = ""
	decision.ArtifactCandidateCatalogSHA256 = ""
	decision.BoundMemberSource = ""
	decision.EvaluatedReleaseGeneration = 0
	return decision
}

func mapDecisionStoreError(err error) error {
	var failure *modelAdmissionDecisionError
	switch {
	case errors.As(err, &failure):
		return err
	case errors.Is(err, errModelAdmissionStaleHead):
		return decisionFail(http.StatusConflict, "stale_head")
	case errors.Is(err, errModelAdmissionReplayConflict):
		return decisionFail(http.StatusConflict, "idempotency_conflict")
	case errors.Is(err, errModelAdmissionNoPending):
		return decisionFail(http.StatusConflict, "no_pending_decision")
	case errors.Is(err, errModelAdmissionPendingExpired):
		return decisionFail(http.StatusConflict, "pending_expired")
	case errors.Is(err, errModelAdmissionPendingConsumed):
		return decisionFail(http.StatusConflict, "pending_consumed")
	}
	return err
}

// bindDecisionToCatalogLocked evaluates R003 (i)–(iii) (and (iv) for
// settlement_capable) under the release read lock and binds the decision:
// the Tier-2 row material (composite proof of the row binding and pricing
// key), the resolved key and the refreshed member set; for
// settlement_capable the session's pinned member as the settlement identity.
func (s *Server) bindDecisionToCatalogLocked(decision *ModelAdmissionEvent, head ModelAdmissionEvent, settlement bool, provider pool.Provider, hasSession bool) error {
	current, compatible := s.autotuneCatalogSnapshot()
	eval := s.evaluateCatalogPreconditionsLocked(head, current)
	if eval.decisionCode != "" {
		return decisionFail(http.StatusConflict, eval.decisionCode)
	}
	decision.CatalogID = eval.material.CatalogID
	decision.CatalogBodyDigest = eval.material.CatalogBodyDigest
	decision.CatalogSignatureKeyID = eval.material.CatalogSignatureKeyID
	decision.CatalogSignaturePubkeyFingerprint = eval.material.CatalogSignaturePubkeyFingerprint
	decision.CatalogModelKey = head.CatalogModelKey
	decision.CatalogMembers = eval.members
	decision.CatalogReleaseID = current.Version
	decision.CatalogCandidateSHA256 = current.SHA256
	decision.CatalogSignerKeyID = current.SignerKeyID
	// A catalog_priced decision binds the key and the member set; the row's
	// own pair is the expected identity of record (proof of the row binding).
	decision.ExpectedCatalogModelHash = eval.material.ExpectedModelHash
	decision.ExpectedCatalogModelHashAlgorithm = eval.material.ExpectedModelHashAlgorithm
	if !settlement {
		return nil
	}
	// (iv) the provider's single live session, bound to this candidate.
	if !hasSession {
		return decisionFail(http.StatusConflict, "no_verified_session")
	}
	member, binding, ok := s.settlementSessionMemberLocked(head, provider, current, compatible)
	if !ok {
		return decisionFail(http.StatusConflict, "no_verified_session")
	}
	decision.ExpectedCatalogModelHash = member.Hash
	decision.ExpectedCatalogModelHashAlgorithm = member.HashAlgorithm
	decision.BoundMemberSource = member.Source
	if member.Source == modelAdmissionMemberSourceArtifactFeed {
		decision.ArtifactFeedSHA256 = binding.Provenance.FeedSHA256
		decision.ArtifactID = binding.Member.ArtifactID
		decision.ArtifactHash = binding.Member.Hash
		decision.ArtifactHashAlgorithm = binding.Member.HashAlgorithm
		decision.ArtifactFeedSignerKeyID = binding.Provenance.SignerKeyID
		decision.ArtifactCandidateCatalogSHA256 = binding.Provenance.CandidateCatalogSHA256
	}
	return nil
}

// settlementSessionMemberLocked is R003(iv): the live session (read from
// the registry BEFORE the release read lock — lock order) is bound to the
// candidate at its current head, admitted on the current release or a
// retained compatible-previous release carrying the same row tuple
// (resolved by the session's EXACT release id, never by its stored
// admission mode, which goes stale after a re-stamp), pinned hash_verified
// for a recorded admissible member resolved in the session's OWN release's
// fresh identity set, with its receipt key present. Until the
// SPEC-010-R007(e) runtime path reports another source, a session presents
// only `mlx_cache` and only an `mlx_safetensors` member can bind: the
// offer's signed `runtime_source` is a provider assertion, never a
// live-session fact.
func (s *Server) settlementSessionMemberLocked(head ModelAdmissionEvent, provider pool.Provider, current *autotune.Catalog, compatible map[string]*autotune.Catalog) (ModelAdmissionCatalogMember, artifactidentityBinding, bool) {
	none := ModelAdmissionCatalogMember{}
	if provider.ModelAdmissionCandidateID != head.CandidateID || provider.ModelAdmissionCoordinatorEventID != head.CoordinatorEventID {
		return none, artifactidentityBinding{}, false
	}
	if !sessionReceiptKeyPresent(provider) {
		return none, artifactidentityBinding{}, false
	}
	if head.RuntimeSource != modelAdmissionRuntimeSourceMLXCache {
		return none, artifactidentityBinding{}, false
	}
	sessionCatalog, _, _, ok := resolveProviderCatalogIn(provider, current, compatible)
	if !ok || sessionCatalog == nil {
		return none, artifactidentityBinding{}, false
	}
	row, ok := sessionCatalog.Row(head.CatalogModelKey)
	if !ok || autotune.NormalizeModelID(row.ModelID) != autotune.NormalizeModelID(head.CatalogRowModelID) || strings.TrimSpace(row.ModelSHA256) != head.CatalogRowModelSHA256 {
		return none, artifactidentityBinding{}, false
	}
	member, ok := sessionBoundMember(provider, head)
	if !ok || member.HashAlgorithm != modelidentity.SnapshotManifestV1 {
		return none, artifactidentityBinding{}, false
	}
	if member.Source == modelAdmissionMemberSourceCandidateRow {
		return member, artifactidentityBinding{}, true
	}
	set := s.usableIdentitySetLocked(sessionCatalog)
	resolved, ok := set.Resolve(member.HashAlgorithm, member.Hash)
	if !ok || resolved.Member.ModelKey != head.CatalogModelKey || resolved.Member.ArtifactID != member.ArtifactID || !resolved.Member.AllowsRuntimeSource(head.RuntimeSource) {
		return none, artifactidentityBinding{}, false
	}
	return member, artifactidentityBinding(resolved), true
}

// ---- POST /admin/model-admission/decisions/<pending_decision_id>/approve

func (s *Server) handleAdminModelAdmissionApprove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "method not allowed"))
		return
	}
	actor, ok := s.authorizedModelAdmissionOperator(w, r)
	if !ok {
		return
	}
	if s.modelAdmissions == nil {
		writeJSON(w, http.StatusInternalServerError, modelAdmissionError("model_admission_store_error", "model admission store unavailable"))
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/admin/model-admission/decisions/")
	pathID, tail, _ := strings.Cut(rest, "/")
	if tail != "approve" || !modelAdmissionPendingIDPattern.MatchString(pathID) {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "invalid model admission approval path"))
		return
	}
	var body modelAdmissionApproveRequest
	r.Body = http.MaxBytesReader(w, r.Body, modelAdmissionMaxBodyBytes+1)
	if err := decodeStrictJSON(r.Body, &body); err != nil || !body.validate() {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "invalid model admission approval request"))
		return
	}
	// (a) the path and body ids must be equal.
	if body.PendingDecisionID != pathID {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "pending_decision_id mismatch"))
		return
	}
	var (
		outcome modelAdmissionDecisionOutcome
		err     error
	)
	s.withProviderSection(body.ProviderID, func(section *providerSection) {
		outcome, err = s.applyModelAdmissionApprovalLocked(r.Context(), actor, body, section)
	})
	if err != nil {
		writeModelAdmissionDecisionError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, s.modelAdmissionDecisionResponse(outcome))
}

// applyModelAdmissionApprovalLocked is the approval precedence (a)–(g),
// evaluated as one release reader after the live session was read.
func (s *Server) applyModelAdmissionApprovalLocked(ctx context.Context, actor string, body modelAdmissionApproveRequest, section *providerSection) (modelAdmissionDecisionOutcome, error) {
	digest := body.digest()
	requestID := body.requestID()
	var provider pool.Provider
	hasSession := false
	if s.pool != nil {
		provider, hasSession = s.pool.Resolve(body.ProviderID, "")
	}
	var (
		outcome  modelAdmissionDecisionOutcome
		pending  PendingModelAdmissionDecision
		evalErr  error
		appended bool
	)
	s.withReleaseRead(func() {
		outcome, pending, appended, evalErr = s.evaluateModelAdmissionApprovalLocked(ctx, actor, body, digest, requestID, provider, hasSession)
	})
	if evalErr != nil {
		return modelAdmissionDecisionOutcome{}, mapDecisionStoreError(evalErr)
	}
	if appended {
		s.afterModelAdmissionAppendLocked(ctx, body.ProviderID, section)
		s.log.Info().
			Str("admin_action", "model_admission_decision_approved").
			Str("actor", actor).
			Str("requested_by", pending.RequestedBy).
			Str("provider_id", body.ProviderID).
			Str("candidate_id", body.CandidateID).
			Str("pending_decision_id", pending.ID).
			Str("coordinator_event_id", outcome.event.CoordinatorEventID).
			Msg("model admission settlement_capable approved")
	}
	return outcome, nil
}

func (s *Server) evaluateModelAdmissionApprovalLocked(ctx context.Context, actor string, body modelAdmissionApproveRequest, digest, requestID string, provider pool.Provider, hasSession bool) (modelAdmissionDecisionOutcome, PendingModelAdmissionDecision, bool, error) {
	none := PendingModelAdmissionDecision{}
	pending, found, err := s.modelAdmissions.PendingModelAdmissionDecision(ctx, body.PendingDecisionID)
	if err != nil {
		return modelAdmissionDecisionOutcome{}, none, false, err
	}
	// (a) the bound fields must equal the stored record — before (b): every
	// divergence of the closed approval body is a bound-field disagreement.
	if found && (pending.ProviderID != body.ProviderID || pending.CandidateID != body.CandidateID || pending.EvaluatedHead != body.ExpectedCoordinatorEventID) {
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusBadRequest, "invalid_request")
	}
	// (b) approval idempotency, before any pending or head check.
	if prior, found, err := s.modelAdmissions.ModelAdmissionEventByRequestID(ctx, body.ProviderID, requestID); err != nil {
		return modelAdmissionDecisionOutcome{}, none, false, err
	} else if found {
		if prior.PayloadDigestSHA256 != digest {
			return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "idempotency_conflict")
		}
		return modelAdmissionDecisionOutcome{event: prior, replayed: true}, none, false, nil
	}
	if found && pending.ApprovalRequestKey == requestID && pending.ApprovalDigest != digest {
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "idempotency_conflict")
	}
	// (c) pending status.
	switch {
	case !found || pending.Invalidated:
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "no_pending_decision")
	case !pending.ConsumedAt.IsZero():
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "pending_consumed")
	case s.now().UTC().After(pending.ExpiresAt):
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "pending_expired")
	}
	// (d) a distinct actor.
	if pending.RequestedBy == actor {
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "dual_control_required")
	}
	head, found, err := s.modelAdmissions.LatestModelAdmissionStatus(ctx, body.ProviderID, body.CandidateID)
	if err != nil {
		return modelAdmissionDecisionOutcome{}, none, false, err
	}
	if !found {
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusNotFound, "no_offer")
	}
	// (e) the head must still be the evaluated head, else the record dies.
	if head.CoordinatorEventID != pending.EvaluatedHead {
		if err := s.modelAdmissions.InvalidatePendingModelAdmissionDecisions(ctx, body.ProviderID, body.CandidateID); err != nil {
			return modelAdmissionDecisionOutcome{}, none, false, err
		}
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "stale_head")
	}
	if !modelAdmissionCoordinatorTransitionAllowed(head.State, pending.NextState) {
		return modelAdmissionDecisionOutcome{}, none, false, decisionFail(http.StatusConflict, "invalid_transition")
	}
	decision := operatorDecisionFromHead(head, pending.NextState, actor, pending.ReasonCode, requestID, "operator_approval_nonce_"+digest[:32], digest, s.now())
	generation := s.artifactIdentitySets.generationLocked()
	// (f) the R003 preconditions re-evaluated in full.
	if err := s.bindDecisionToCatalogLocked(&decision, head, true, provider, hasSession); err != nil {
		return modelAdmissionDecisionOutcome{}, none, false, err
	}
	decision.EvaluatedReleaseGeneration = generation
	// (g) release-generation re-compare and append; the same atomic step
	// marks the record consumed by this approval (an identical-key retry
	// replays, a distinct-key one is `pending_consumed`).
	stored, replayed, err := s.modelAdmissions.AppendModelAdmissionApproval(ctx, decision, head.CoordinatorEventID, PendingModelAdmissionApproval{
		PendingID: pending.ID, RequestKey: requestID, Digest: digest, Actor: actor,
	})
	if err != nil {
		return modelAdmissionDecisionOutcome{}, none, false, err
	}
	return modelAdmissionDecisionOutcome{event: stored, replayed: replayed}, pending, !replayed, nil
}

// ---- GET /admin/model-admission/offers?provider_id=

func (s *Server) handleAdminModelAdmissionOffers(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "method not allowed"))
		return
	}
	if _, ok := s.authorizedModelAdmissionOperator(w, r); !ok {
		return
	}
	if s.modelAdmissions == nil {
		writeJSON(w, http.StatusInternalServerError, modelAdmissionError("model_admission_store_error", "model admission store unavailable"))
		return
	}
	query := r.URL.Query()
	providerID := query.Get("provider_id")
	if len(query) != 1 || len(query["provider_id"]) != 1 || !modelAdmissionOperatorProviderPattern.MatchString(providerID) {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_request", "provider_id is the only accepted query parameter"))
		return
	}
	events, err := s.modelAdmissions.LatestModelAdmissionStatusesForProvider(r.Context(), providerID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, modelAdmissionError("model_admission_store_error", "model admission listing failed"))
		return
	}
	var provider pool.Provider
	hasSession := false
	if s.pool != nil {
		provider, hasSession = s.pool.Resolve(providerID, "")
	}
	items := make([]map[string]any, 0, len(events))
	for _, event := range events {
		if len(items) >= modelAdmissionMaxCandidates {
			break
		}
		items = append(items, modelAdmissionOfferListItem(event, provider, hasSession))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"schema":       modelAdmissionOfferListSchema,
		"generated_at": s.now().UTC().Format(time.RFC3339Nano),
		"provider_id":  providerID,
		"candidates":   items,
	})
}

func modelAdmissionMemberRecord(member ModelAdmissionCatalogMember) map[string]any {
	return map[string]any{
		"source":                            member.Source,
		"hash_algorithm":                    member.HashAlgorithm,
		"hash":                              member.Hash,
		"artifact_id":                       nullString(member.ArtifactID),
		"artifact_feed_sha256":              nullString(member.ArtifactFeedSHA256),
		"artifact_feed_signer_key_id":       nullString(member.ArtifactFeedSignerKeyID),
		"artifact_candidate_catalog_sha256": nullString(member.ArtifactCandidateCatalogSHA256),
	}
}

func modelAdmissionOfferListItem(event ModelAdmissionEvent, provider pool.Provider, hasSession bool) map[string]any {
	members := make([]map[string]any, 0, len(event.CatalogMembers))
	for i, member := range event.CatalogMembers {
		if i >= modelAdmissionOfferListMemberCap {
			break
		}
		members = append(members, modelAdmissionMemberRecord(member))
	}
	// Pre-v0.1.5 records carry no match: listed as unmatched / no match.
	matchState, matchReason := event.CatalogMatchState, event.CatalogMatchReason
	if matchState == "" {
		matchState = modelAdmissionCatalogUnmatched
	}
	if matchReason == "" {
		matchReason = modelAdmissionMatchReasonNoArtifactMatch
		if matchState == modelAdmissionCatalogMatched {
			matchReason = modelAdmissionMatchReasonNone
		}
	}
	item := map[string]any{
		"candidate_id":             event.CandidateID,
		"served_model_ref":         event.ServedModelRef,
		"runtime_source":           event.RuntimeSource,
		"admission_state":          event.State,
		"coordinator_event_id":     event.CoordinatorEventID,
		"state_observed_at":        event.CreatedAt.UTC().Format(time.RFC3339Nano),
		"reason_code":              event.ReasonCode,
		"catalog_match_state":      matchState,
		"catalog_match_reason":     matchReason,
		"catalog_model_key":        nullString(event.CatalogModelKey),
		"catalog_row_model_id":     nullString(event.CatalogRowModelID),
		"catalog_row_model_sha256": nullString(event.CatalogRowModelSHA256),
		"catalog_release_id":       nullString(event.CatalogReleaseID),
		"catalog_candidate_sha256": nullString(event.CatalogCandidateSHA256),
		"catalog_signer_key_id":    nullString(event.CatalogSignerKeyID),
		"catalog_members":          members,
		"last_event_actor":         event.Actor,
		"session":                  nil,
	}
	if hasSession {
		bound := provider.ModelAdmissionCandidateID == event.CandidateID
		session := map[string]any{
			"bound":                        bound,
			"bound_coordinator_event_id":   nil,
			"validated_release_generation": nil,
			"verified_member":              nil,
			"receipt_key_present":          sessionReceiptKeyPresent(provider),
			"catalog_release_id":           nullString(provider.CatalogReleaseID),
		}
		if bound {
			session["bound_coordinator_event_id"] = provider.ModelAdmissionCoordinatorEventID
			session["validated_release_generation"] = provider.ModelAdmissionValidatedReleaseGeneration
		}
		if member, ok := sessionBoundMember(provider, event); ok {
			session["verified_member"] = modelAdmissionMemberRecord(member)
		}
		item["session"] = session
	}
	return item
}

// ---- route-time compare-and-insert (R001 / R003)

// ModelAdmissionRouteExpectation is what a route attempt evaluated: the
// candidate's head, the session binding's head and the provider's binding
// generation at evaluation time.
type ModelAdmissionRouteExpectation struct {
	ProviderID         string
	CandidateID        string
	CoordinatorEventID string
	BindingGeneration  uint64
	// SessionEpoch is the session identity epoch the attempt evaluated
	// (pool.Provider.ModelAdmissionSessionEpoch): identity drift the drift
	// path has not yet appended still fails the attempt closed.
	SessionEpoch uint64
}

// ErrModelAdmissionRouteStale is the compare-and-insert's fail-closed answer.
var ErrModelAdmissionRouteStale = errors.New("BYOM model admission route snapshot expectation no longer holds")

// CompareAndInsertModelAdmissionRouteSnapshot is the SPEC-047-R001 route-time
// compare-and-insert. Pre-check (under the release read lock): the
// candidate's head, the session binding read from the registry BEFORE the
// hold (lock order), the provider's binding generation, the session
// identity epoch, and the binding's validated release generation, which
// must equal the published one (0 means never validated). The insert runs
// OUTSIDE the release hold (a SQLite write must not block a queued
// publisher and, through it, every hello/heartbeat reader). Post-check
// (under a fresh read hold, then the registry): the generation, the head,
// the binding generation, the binding and the epoch are re-read; any
// difference fails the attempt closed — the immutable snapshot stands,
// nothing is dispatched or settled under it. Appends stay serialized by the
// provider section, which the route path never takes.
func (s *Server) CompareAndInsertModelAdmissionRouteSnapshot(ctx context.Context, expect ModelAdmissionRouteExpectation, insert func() error) error {
	if s.modelAdmissions == nil || s.pool == nil {
		return ErrModelAdmissionRouteStale
	}
	provider, ok := s.pool.Resolve(expect.ProviderID, "")
	if !ok {
		return ErrModelAdmissionRouteStale
	}
	if provider.ModelAdmissionCandidateID != expect.CandidateID || provider.ModelAdmissionCoordinatorEventID != expect.CoordinatorEventID ||
		provider.ModelAdmissionValidatedReleaseGeneration == 0 || provider.ModelAdmissionSessionEpoch != expect.SessionEpoch ||
		s.modelAdmissionSections.get(expect.ProviderID).generation.Load() != expect.BindingGeneration {
		return ErrModelAdmissionRouteStale
	}
	headOK := func() bool {
		head, found, err := s.modelAdmissions.LatestModelAdmissionStatus(ctx, expect.ProviderID, expect.CandidateID)
		return err == nil && found && head.CoordinatorEventID == expect.CoordinatorEventID && head.State == "settlement_capable"
	}
	var generation uint64
	stale := false
	s.withReleaseRead(func() {
		generation = s.artifactIdentitySets.generationLocked()
		stale = generation == 0 || provider.ModelAdmissionValidatedReleaseGeneration != generation || !headOK()
	})
	if stale {
		return ErrModelAdmissionRouteStale
	}
	if err := insert(); err != nil {
		return err
	}
	s.withReleaseRead(func() {
		stale = s.artifactIdentitySets.generationLocked() != generation || !headOK() ||
			s.modelAdmissionSections.get(expect.ProviderID).generation.Load() != expect.BindingGeneration
	})
	if stale {
		return ErrModelAdmissionRouteStale
	}
	after, ok := s.pool.Resolve(expect.ProviderID, "")
	if !ok || after.ModelAdmissionCandidateID != expect.CandidateID || after.ModelAdmissionCoordinatorEventID != expect.CoordinatorEventID ||
		after.ModelAdmissionBindingGeneration != provider.ModelAdmissionBindingGeneration || after.ModelAdmissionSessionEpoch != expect.SessionEpoch ||
		after.ModelAdmissionValidatedReleaseGeneration != generation {
		return ErrModelAdmissionRouteStale
	}
	return nil
}

// Tier2RouteSnapshotMaterial is the row material on the catalog reference
// the decision path binds against (the buyer's route-time lookup).
func (s *Server) Tier2RouteSnapshotMaterial(modelID, reportedHash string) (tier2.RouteSnapshotMaterial, bool) {
	return s.catalogRef().RouteSnapshotMaterial(modelID, reportedHash)
}
