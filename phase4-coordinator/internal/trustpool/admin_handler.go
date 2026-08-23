package trustpool

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

const AdminSchemaVersion = "macprovider.trustpool-admin.v1"
const maxAdminEventBodyBytes = 64 * 1024

// AdminDeps wires the default-off SPEC-043 operator control surface. The
// handler accepts durable pool events only after replay-checking the whole
// history, then refreshes the live registry pointer held by the buyer server.
type AdminDeps struct {
	Store       *Store
	Registry    *Registry
	OperatorKey string
}

func NewAdminHandler(deps AdminDeps) http.Handler {
	return &adminHandler{deps: deps}
}

type adminHandler struct {
	deps AdminDeps
	mu   sync.Mutex
}

func (h *adminHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.deps.Store == nil {
		writeAdminJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]string{"code": "unavailable"}})
		return
	}
	if strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/signed-lifecycle") {
		h.handleSignedLifecycle(w, r)
		return
	}
	if !auth.OperatorOnlyBearerMatches(r.Header, h.deps.OperatorKey) {
		writeAdminJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]string{"code": "unauthorized"}})
		return
	}
	switch {
	case r.URL.Path == "/admin/trust-pools/events":
		h.handleAppendEvent(w, r)
	case r.URL.Path == "/admin/trust-pools/creators":
		h.handleUpsertCreator(w, r)
	case r.URL.Path == "/admin/trust-pools/root-registration-nonces":
		h.handleIssueRootRegistrationNonce(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/creators/"):
		h.handleGetCreator(w, r)
	case r.URL.Path == "/admin/trust-pools/pools":
		h.handleListPools(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/reviewed-distribution-artifact"):
		h.handleReviewedDistributionArtifact(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/public-announcement"):
		h.handlePublicAnnouncementApproval(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/promote"):
		h.handlePromotePool(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/lifecycle"):
		h.handleRestrictiveLifecycle(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/audit"):
		h.handlePoolAudit(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/health"):
		h.handlePoolHealth(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/distribution"):
		h.handlePoolDistribution(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/"):
		h.handleGetPool(w, r)
	default:
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
	}
}

func (h *adminHandler) handleUpsertCreator(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	var approval CreatorApproval
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&approval); err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	committed, err := h.deps.Store.UpsertCreatorApproval(r.Context(), approval)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	if !h.refreshRegistryIfAhead(w, state) {
		return
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{"creator": committed})
}

func (h *adminHandler) handleGetCreator(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	creatorID := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/admin/trust-pools/creators/"))
	if creatorID == "" || strings.Contains(creatorID, "/") {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	approval, ok, err := h.deps.Store.CreatorApproval(r.Context(), creatorID)
	if err != nil {
		h.writeLookupError(w, "creator_lookup_failed", err)
		return
	}
	if !ok {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"creator": approval})
}

func (h *adminHandler) handleIssueRootRegistrationNonce(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	var issue RootRegistrationNonceIssue
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&issue); err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	operationID, err := resolveOperationID(strings.TrimSpace(issue.OperationID), r.Header)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	issue.OperationID = operationID
	record, err := h.deps.Store.IssueRootRegistrationNonce(r.Context(), issue)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	writeAdminJSON(w, http.StatusCreated, map[string]any{"root_registration_nonce": record})
}

func (h *adminHandler) handleAppendEvent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	var e DurableEvent
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&e); err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var err error
	e, err = normalizeAdminEvent(r, e)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if e.EventType == EventLifecycleChanged && e.Lifecycle == LifecycleActive {
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "activation_requires_promotion"}})
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	state, committed, _, err := h.deps.Store.AppendValidatedEvent(r.Context(), e)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if !h.refreshRegistryIfAhead(w, state) {
		return
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{
		"event": committed,
		"pool":  adminPoolResponse(state.Pools[committed.PoolID], state.RouteGateCheckedAt),
	})
}

type promotionRequest struct {
	OperationID  string    `json:"operation_id,omitempty"`
	TimestampUTC time.Time `json:"timestamp_utc,omitempty"`
	Reason       string    `json:"reason,omitempty"`
}

type restrictiveLifecycleRequest struct {
	OperationID  string    `json:"operation_id,omitempty"`
	TimestampUTC time.Time `json:"timestamp_utc,omitempty"`
	Lifecycle    string    `json:"lifecycle"`
	Reason       string    `json:"reason,omitempty"`
}

type signedLifecycleRequest struct {
	Control    signedLifecycleControlJSON     `json:"control"`
	Signatures []signedLifecycleSignatureJSON `json:"signatures"`
}

type signedLifecycleControlJSON struct {
	PoolID             string `json:"pool_id"`
	ManifestVersion    uint64 `json:"manifest_version"`
	ManifestCoreDigest string `json:"manifest_core_digest"`
	SignerSetVersion   uint64 `json:"signer_set_version"`
	OperationID        string `json:"operation_id"`
	Action             string `json:"action"`
	TargetProviderID   string `json:"target_provider_id,omitempty"`
	Reason             string `json:"reason,omitempty"`
	IssuedAtUnix       uint64 `json:"issued_at_unix"`
	ExpiresAtUnix      uint64 `json:"expires_at_unix"`
}

type signedLifecycleSignatureJSON struct {
	KeyID     string `json:"key_id"`
	Signature string `json:"signature"`
}

func (h *adminHandler) handlePromotePool(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := strings.TrimSpace(strings.TrimPrefix(strings.TrimSuffix(r.URL.Path, "/promote"), "/admin/trust-pools/pools/"))
	if poolID == "" || strings.Contains(poolID, "/") {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	var body promotionRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil && err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	operationID, err := resolveOperationID(strings.TrimSpace(body.OperationID), r.Header)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	e := DurableEvent{
		OperationID:  operationID,
		TimestampUTC: body.TimestampUTC,
		EventType:    EventLifecycleChanged,
		PoolID:       poolID,
		Lifecycle:    LifecycleActive,
		Reason:       strings.TrimSpace(body.Reason),
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	state, committed, _, err := h.deps.Store.PromotePool(r.Context(), e)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if !h.refreshRegistryIfAhead(w, state) {
		return
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{
		"event": committed,
		"pool":  adminPoolResponse(state.Pools[committed.PoolID], state.RouteGateCheckedAt),
	})
}

func (h *adminHandler) handleSignedLifecycle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedAdminPath(r.URL.Path, "/signed-lifecycle")
	if poolID == "" {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	var body signedLifecycleRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	control, err := parseSignedLifecycleControl(body.Control)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if control.PoolID != poolID {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "pool_id_mismatch"}})
		return
	}
	if strings.TrimSpace(body.Control.OperationID) == "" {
		h.writeMutationError(w, ErrSignedControlProofPath)
		return
	}
	operationID, err := resolveOperationID(strings.TrimSpace(control.OperationID), r.Header)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	control.OperationID = operationID
	body.Control.OperationID = operationID
	switch control.Action {
	case LifecyclePaused, LifecycleDraining, LifecycleRetired, poolmanifest.EmergencyLifecycleRevokeImmediate:
	case LifecycleActive:
		h.writeMutationError(w, ErrActivationRequiresPromotion)
		return
	default:
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
		return
	}
	if control.IssuedAtUnix > uint64(1<<63-1) {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
		return
	}
	sigs, err := parseSignedLifecycleSignatures(body.Signatures)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	controlProof, sigProof, err := signedLifecycleProofs(body.Control, body.Signatures)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	e := DurableEvent{
		OperationID:        operationID,
		TimestampUTC:       time.Unix(int64(control.IssuedAtUnix), 0).UTC(),
		EventType:          EventLifecycleChanged,
		PoolID:             poolID,
		Lifecycle:          control.Action,
		Reason:             strings.TrimSpace(control.Reason),
		ManifestVersion:    control.ManifestVersion,
		ManifestCoreDigest: strings.TrimSpace(body.Control.ManifestCoreDigest),
		SignedControl:      controlProof,
		ControlSignatures:  sigProof,
	}
	if control.Action == poolmanifest.EmergencyLifecycleRevokeImmediate {
		e.EventType = EventMemberRevoked
		e.Lifecycle = ""
		e.ProviderID = control.TargetProviderID
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	existing, ok, err := h.deps.Store.ExistingEvent(r.Context(), operationID)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if ok {
		state, err := h.deps.Store.Reconstruct(r.Context())
		if err != nil {
			h.writeReconstructError(w, err)
			return
		}
		if !sameDurableEvent(existing, e) {
			h.writeMutationError(w, ErrConflictingOperationID)
			return
		}
		if !h.refreshRegistryIfAhead(w, state) {
			return
		}
		writeAdminJSON(w, http.StatusAccepted, map[string]any{
			"event": existing,
			"pool":  adminPoolResponse(state.Pools[existing.PoolID], state.RouteGateCheckedAt),
		})
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	pool := state.Pools[poolID]
	if pool == nil {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	rawSnapshot, err := canonicalBase64(pool.ManifestSnapshot)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	snapshot, err := poolmanifest.ParseManifestSnapshot(rawSnapshot)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if err := poolmanifest.VerifyEmergencyLifecycleControl(control, sigs, snapshot, uint64(time.Now().UTC().Unix())); err != nil {
		h.writeMutationError(w, err)
		return
	}
	state, committed, _, err := h.deps.Store.appendSignedControlEvent(r.Context(), e)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if !h.refreshRegistryIfAhead(w, state) {
		return
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{
		"event": committed,
		"pool":  adminPoolResponse(state.Pools[committed.PoolID], state.RouteGateCheckedAt),
	})
}

func (h *adminHandler) handleRestrictiveLifecycle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedAdminPath(r.URL.Path, "/lifecycle")
	if poolID == "" {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	var body restrictiveLifecycleRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	operationID, err := resolveOperationID(strings.TrimSpace(body.OperationID), r.Header)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	lifecycle := strings.TrimSpace(body.Lifecycle)
	switch lifecycle {
	case LifecyclePaused, LifecycleDraining, LifecycleRetired:
	case LifecycleActive:
		h.writeMutationError(w, ErrActivationRequiresPromotion)
		return
	default:
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
		return
	}
	e := DurableEvent{
		OperationID:  operationID,
		TimestampUTC: body.TimestampUTC,
		EventType:    EventLifecycleChanged,
		PoolID:       poolID,
		Lifecycle:    lifecycle,
		Reason:       strings.TrimSpace(body.Reason),
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	state, committed, _, err := h.deps.Store.AppendValidatedEvent(r.Context(), e)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if !h.refreshRegistryIfAhead(w, state) {
		return
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{
		"event": committed,
		"pool":  adminPoolResponse(state.Pools[committed.PoolID], state.RouteGateCheckedAt),
	})
}

func (h *adminHandler) handlePublicAnnouncementApproval(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedAdminPath(r.URL.Path, "/public-announcement")
	if poolID == "" {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	var approval PublicAnnouncementApproval
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&approval); err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	if bodyPoolID := strings.TrimSpace(approval.PoolID); bodyPoolID != "" && bodyPoolID != poolID {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "pool_id_mismatch"}})
		return
	}
	operationID, err := resolveOperationID(strings.TrimSpace(approval.OperationID), r.Header)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	approval.PoolID = poolID
	approval.OperationID = operationID
	h.mu.Lock()
	defer h.mu.Unlock()
	committed, err := h.deps.Store.UpsertPublicAnnouncementApproval(r.Context(), approval)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{
		"public_announcement": committed,
		"pool":                adminPoolResponse(state.Pools[poolID], state.RouteGateCheckedAt),
	})
}

func (h *adminHandler) handleReviewedDistributionArtifact(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedAdminPath(r.URL.Path, "/reviewed-distribution-artifact")
	if poolID == "" {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	var artifact ReviewedDistributionArtifact
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&artifact); err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	var trailing struct{}
	if err := dec.Decode(&trailing); err != io.EOF {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
		return
	}
	if bodyPoolID := strings.TrimSpace(artifact.PoolID); bodyPoolID != "" && bodyPoolID != poolID {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "pool_id_mismatch"}})
		return
	}
	operationID, err := resolveOperationID(strings.TrimSpace(artifact.OperationID), r.Header)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	artifact.PoolID = poolID
	artifact.OperationID = operationID
	h.mu.Lock()
	defer h.mu.Unlock()
	committed, err := h.deps.Store.UpsertReviewedDistributionArtifact(r.Context(), artifact)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{"reviewed_distribution_artifact": committed})
}

func (h *adminHandler) handleListPools(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	ids := make([]string, 0, len(state.Pools))
	for id := range state.Pools {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	pools := make([]adminPoolState, 0, len(ids))
	for _, id := range ids {
		pools = append(pools, adminPoolResponse(state.Pools[id], state.RouteGateCheckedAt))
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"pools": pools})
}

func (h *adminHandler) handleGetPool(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/admin/trust-pools/pools/"))
	if poolID == "" || strings.Contains(poolID, "/") {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	pool := state.Pools[poolID]
	if pool == nil {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"pool": adminPoolResponse(pool, state.RouteGateCheckedAt)})
}

func (h *adminHandler) handlePoolAudit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedAdminPath(r.URL.Path, "/audit")
	if poolID == "" {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	if state.Pools[poolID] == nil {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	events, err := h.deps.Store.Events(r.Context())
	if err != nil {
		h.writeLookupError(w, "audit_lookup_failed", err)
		return
	}
	filtered := make([]DurableEvent, 0)
	rootRegistrationOps := make(map[string]bool)
	for _, e := range events {
		if e.PoolID == poolID {
			filtered = append(filtered, e)
			if e.EventType == EventRootIssuerRegistered && e.OperationID != "" {
				rootRegistrationOps[e.OperationID] = true
			}
		}
	}
	nonceAudit, err := h.rootRegistrationNonceAuditRecords(r.Context(), state.Pools[poolID], rootRegistrationOps)
	if err != nil {
		h.writeLookupError(w, "audit_lookup_failed", err)
		return
	}
	var creatorApproval any
	if approval, ok := state.CreatorApprovals[state.Pools[poolID].CreatorAccountID]; ok {
		creatorApproval = approval
	}
	var publicAnnouncement any
	if approval, ok := state.PublicAnnouncements[poolID]; ok {
		publicAnnouncement = approval
	}
	publicAnnouncementHistory, err := h.deps.Store.PublicAnnouncementHistory(r.Context(), poolID)
	if err != nil {
		h.writeLookupError(w, "audit_lookup_failed", err)
		return
	}
	var reviewedArtifact any
	if artifact, ok, err := h.deps.Store.ReviewedDistributionArtifact(r.Context(), poolID); err != nil {
		h.writeLookupError(w, "audit_lookup_failed", err)
		return
	} else if ok {
		reviewedArtifact = artifact
	}
	reviewedArtifactHistory, err := h.deps.Store.ReviewedDistributionArtifactHistory(r.Context(), poolID)
	if err != nil {
		h.writeLookupError(w, "audit_lookup_failed", err)
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{
		"pool_id":                                poolID,
		"creator_approval":                       creatorApproval,
		"reviewed_distribution_artifact":         reviewedArtifact,
		"reviewed_distribution_artifact_history": reviewedArtifactHistory,
		"public_announcement":                    publicAnnouncement,
		"public_announcement_history":            publicAnnouncementHistory,
		"root_registration_nonces":               nonceAudit,
		"events":                                 filtered,
		"nonce_material_disclosure":              "nonce digests are exported here; consumed nonce material may still appear inside root-registration durable events for replay compatibility",
	})
}

type adminRootRegistrationNonceAudit struct {
	OperationID            string `json:"operation_id,omitempty"`
	NonceSHA256            string `json:"nonce_sha256"`
	CreatorAccountID       string `json:"creator_account_id"`
	ApprovalRecordID       string `json:"approval_record_id"`
	CurrentApprovalVersion string `json:"current_approval_version"`
	LaunchEnvironment      string `json:"launch_environment"`
	Purpose                string `json:"purpose"`
	ExpiresAtUTC           string `json:"expires_at_utc"`
	IssuedAtUTC            string `json:"issued_at_utc"`
	ConsumedOperationID    string `json:"consumed_operation_id,omitempty"`
	ConsumedAtUTC          string `json:"consumed_at_utc,omitempty"`
}

func (h *adminHandler) rootRegistrationNonceAuditRecords(ctx context.Context, pool *ReconstructedPoolState, rootRegistrationOps map[string]bool) ([]adminRootRegistrationNonceAudit, error) {
	if h == nil || h.deps.Store == nil || h.deps.Store.db == nil || pool == nil || len(rootRegistrationOps) == 0 {
		return nil, nil
	}
	rows, err := h.deps.Store.db.QueryContext(ctx, `
SELECT operation_id, nonce, creator_account_id, approval_record_id, current_approval_version,
       launch_environment, purpose, expires_at_utc, issued_at_utc, consumed_operation_id, consumed_at_utc
FROM trustpool_root_registration_nonces
WHERE creator_account_id = ? AND approval_record_id = ?
ORDER BY issued_at_utc`, pool.CreatorAccountID, pool.ApprovalRecordID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]adminRootRegistrationNonceAudit, 0)
	for rows.Next() {
		var record adminRootRegistrationNonceAudit
		var operationID, consumedOperationID, consumedAt sql.NullString
		var nonce string
		if err := rows.Scan(
			&operationID,
			&nonce,
			&record.CreatorAccountID,
			&record.ApprovalRecordID,
			&record.CurrentApprovalVersion,
			&record.LaunchEnvironment,
			&record.Purpose,
			&record.ExpiresAtUTC,
			&record.IssuedAtUTC,
			&consumedOperationID,
			&consumedAt,
		); err != nil {
			return nil, err
		}
		if !consumedOperationID.Valid || !rootRegistrationOps[consumedOperationID.String] {
			continue
		}
		if operationID.Valid {
			record.OperationID = operationID.String
		}
		digest := sha256.Sum256([]byte(nonce))
		record.NonceSHA256 = hex.EncodeToString(digest[:])
		if consumedOperationID.Valid {
			record.ConsumedOperationID = consumedOperationID.String
		}
		if consumedAt.Valid {
			record.ConsumedAtUTC = consumedAt.String
		}
		out = append(out, record)
	}
	return out, rows.Err()
}

func (h *adminHandler) handlePoolHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedAdminPath(r.URL.Path, "/health")
	if poolID == "" {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	pool := state.Pools[poolID]
	if pool == nil {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{
		"pool_id":       poolID,
		"health_events": adminHealthEvents(pool, state.RouteGateCheckedAt),
	})
}

func (h *adminHandler) handlePoolDistribution(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedAdminPath(r.URL.Path, "/distribution")
	if poolID == "" {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	pool := state.Pools[poolID]
	if pool == nil {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"distribution_package": buildAdminDistributionPackage(pool, state)})
}

func (h *adminHandler) writeMutationError(w http.ResponseWriter, err error) {
	h.disableRegistryOnMalformed(err)
	switch {
	case errors.Is(err, ErrConflictingOperationID):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "operation_conflict"}})
	case errors.Is(err, ErrActivationRequiresPromotion):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "activation_requires_promotion"}})
	case errors.Is(err, ErrPromotionPreconditionFailed):
		precondition := PromotionPreconditionError{}
		reason := "promotion_precondition_failed"
		if errors.As(err, &precondition) && precondition.Reason != "" {
			reason = precondition.Reason
		}
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "promotion_precondition_failed", "reason": reason}})
	case errors.Is(err, ErrRootRegistrationNonce):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_root_registration_nonce"}})
	case errors.Is(err, ErrCreatorApprovalGate):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "creator_approval_gate_failed"}})
	case errors.Is(err, ErrPublicAnnouncementGate):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "public_announcement_gate_failed"}})
	case errors.Is(err, ErrProhibitedPromiseClaim):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "prohibited_promise_claim"}})
	case errors.Is(err, ErrMalformedDurableEvent):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
	default:
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
	}
}

func (h *adminHandler) writeReconstructError(w http.ResponseWriter, err error) {
	h.disableRegistryOnMalformed(err)
	writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "reconstruct_failed"}})
}

func (h *adminHandler) writeLookupError(w http.ResponseWriter, code string, err error) {
	h.disableRegistryOnMalformed(err)
	writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": code}})
}

func (h *adminHandler) disableRegistryOnMalformed(err error) {
	if h != nil && h.deps.Registry != nil && errors.Is(err, ErrMalformedDurableEvent) {
		h.deps.Registry.Disable()
	}
}

func (h *adminHandler) refreshRegistryIfAhead(w http.ResponseWriter, state *ReconstructedState) bool {
	if h.deps.Registry == nil || state == nil || state.Revision <= h.deps.Registry.Revision() {
		return true
	}
	if err := h.deps.Registry.LoadRouteableSnapshotsAtRevision(state.Revision, state.RouteableSnapshots()); err != nil {
		writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "registry_refresh_failed"}})
		return false
	}
	return true
}

func normalizeAdminEvent(r *http.Request, e DurableEvent) (DurableEvent, error) {
	operationID, err := resolveOperationID(strings.TrimSpace(e.OperationID), r.Header)
	if err != nil {
		return DurableEvent{}, err
	}
	e.OperationID = operationID
	if !e.TimestampUTC.IsZero() {
		e.TimestampUTC = e.TimestampUTC.UTC()
	}
	e.EventType = strings.TrimSpace(e.EventType)
	e.PoolID = strings.TrimSpace(e.PoolID)
	e.CreatorAccountID = strings.TrimSpace(e.CreatorAccountID)
	e.ApprovalRecordID = strings.TrimSpace(e.ApprovalRecordID)
	e.ProviderID = strings.TrimSpace(e.ProviderID)
	e.BuyerAccountID = strings.TrimSpace(e.BuyerAccountID)
	e.Lifecycle = strings.TrimSpace(e.Lifecycle)
	e.Reason = strings.TrimSpace(e.Reason)
	e.MinBinaryVersion = strings.TrimSpace(e.MinBinaryVersion)
	e.ManifestCoreDigest = strings.TrimSpace(e.ManifestCoreDigest)
	e.ManifestSignature = strings.TrimSpace(e.ManifestSignature)
	e.ManifestSnapshot = strings.TrimSpace(e.ManifestSnapshot)
	e.SignedControl = strings.TrimSpace(e.SignedControl)
	e.ControlSignatures = strings.TrimSpace(e.ControlSignatures)
	e.CurrentApprovalVersion = strings.TrimSpace(e.CurrentApprovalVersion)
	e.RootIssuerKeyID = strings.TrimSpace(e.RootIssuerKeyID)
	e.RootIssuerPublicKeyDER = strings.TrimSpace(e.RootIssuerPublicKeyDER)
	e.RootIssuerPublicKeyFingerprint = strings.TrimSpace(e.RootIssuerPublicKeyFingerprint)
	e.RootSignatureAlgorithm = strings.TrimSpace(e.RootSignatureAlgorithm)
	e.ManifestAuthorityRootKeyID = strings.TrimSpace(e.ManifestAuthorityRootKeyID)
	e.ManifestAuthorityRootPublicKey = strings.TrimSpace(e.ManifestAuthorityRootPublicKey)
	e.RootRegistrationSignature = strings.TrimSpace(e.RootRegistrationSignature)
	e.StructuredKeyCustodyDisclosureHash = strings.TrimSpace(e.StructuredKeyCustodyDisclosureHash)
	e.GenesisNonceDigest = strings.TrimSpace(e.GenesisNonceDigest)
	e.IntendedPoolDisplayNameHash = strings.TrimSpace(e.IntendedPoolDisplayNameHash)
	e.LaunchEnvironment = strings.TrimSpace(e.LaunchEnvironment)
	e.RootRegistrationNonce = strings.TrimSpace(e.RootRegistrationNonce)
	e.RootRegistrationNonceExpiry = strings.TrimSpace(e.RootRegistrationNonceExpiry)
	e.RootRegistrationPurpose = strings.TrimSpace(e.RootRegistrationPurpose)
	e.RootRegistrationEnvironment = strings.TrimSpace(e.RootRegistrationEnvironment)
	return e, nil
}

func poolIDFromSuffixedAdminPath(path, suffix string) string {
	poolID := strings.TrimSpace(strings.TrimPrefix(strings.TrimSuffix(path, suffix), "/admin/trust-pools/pools/"))
	if poolID == "" || strings.Contains(poolID, "/") {
		return ""
	}
	return poolID
}

func parseSignedLifecycleControl(in signedLifecycleControlJSON) (poolmanifest.EmergencyLifecycleControl, error) {
	digestHex := strings.TrimSpace(in.ManifestCoreDigest)
	if err := requireLowerHex64(digestHex); err != nil {
		return poolmanifest.EmergencyLifecycleControl{}, err
	}
	digest, err := hex.DecodeString(digestHex)
	if err != nil {
		return poolmanifest.EmergencyLifecycleControl{}, err
	}
	return poolmanifest.EmergencyLifecycleControl{
		PoolID:             strings.TrimSpace(in.PoolID),
		ManifestVersion:    in.ManifestVersion,
		ManifestCoreDigest: digest,
		SignerSetVersion:   in.SignerSetVersion,
		OperationID:        strings.TrimSpace(in.OperationID),
		Action:             strings.TrimSpace(in.Action),
		TargetProviderID:   strings.TrimSpace(in.TargetProviderID),
		Reason:             strings.TrimSpace(in.Reason),
		IssuedAtUnix:       in.IssuedAtUnix,
		ExpiresAtUnix:      in.ExpiresAtUnix,
	}, nil
}

func parseSignedLifecycleSignatures(in []signedLifecycleSignatureJSON) ([]poolmanifest.Signature, error) {
	out := make([]poolmanifest.Signature, 0, len(in))
	for _, s := range in {
		sig, err := canonicalBase64(strings.TrimSpace(s.Signature))
		if err != nil {
			return nil, err
		}
		out = append(out, poolmanifest.Signature{
			KeyID: strings.TrimSpace(s.KeyID),
			Sig:   sig,
		})
	}
	return out, nil
}

func signedLifecycleProofs(control signedLifecycleControlJSON, sigs []signedLifecycleSignatureJSON) (string, string, error) {
	control.PoolID = strings.TrimSpace(control.PoolID)
	control.ManifestCoreDigest = strings.TrimSpace(control.ManifestCoreDigest)
	control.OperationID = strings.TrimSpace(control.OperationID)
	control.Action = strings.TrimSpace(control.Action)
	control.TargetProviderID = strings.TrimSpace(control.TargetProviderID)
	control.Reason = strings.TrimSpace(control.Reason)
	controlBytes, err := json.Marshal(control)
	if err != nil {
		return "", "", err
	}
	normSigs := make([]signedLifecycleSignatureJSON, 0, len(sigs))
	for _, s := range sigs {
		raw, err := canonicalBase64(strings.TrimSpace(s.Signature))
		if err != nil {
			return "", "", err
		}
		normSigs = append(normSigs, signedLifecycleSignatureJSON{
			KeyID:     strings.TrimSpace(s.KeyID),
			Signature: base64.StdEncoding.EncodeToString(raw),
		})
	}
	signatureBytes, err := json.Marshal(normSigs)
	if err != nil {
		return "", "", err
	}
	return string(controlBytes), string(signatureBytes), nil
}

func sameDurableEvent(a, b DurableEvent) bool {
	aa, err := json.Marshal(a)
	if err != nil {
		return false
	}
	bb, err := json.Marshal(b)
	if err != nil {
		return false
	}
	return string(aa) == string(bb)
}

func resolveOperationID(bodyOperationID string, headers http.Header) (string, error) {
	operationID := strings.TrimSpace(bodyOperationID)
	for _, candidate := range []string{strings.TrimSpace(headers.Get("Idempotency-Key")), strings.TrimSpace(headers.Get("X-Operation-ID"))} {
		if candidate == "" {
			continue
		}
		if operationID == "" {
			operationID = candidate
			continue
		}
		if operationID != candidate {
			return "", ErrConflictingOperationID
		}
	}
	return operationID, nil
}

type adminPoolState struct {
	PoolID                         string   `json:"pool_id"`
	CreatorAccountID               string   `json:"creator_account_id"`
	ApprovalRecordID               string   `json:"approval_record_id"`
	Lifecycle                      string   `json:"lifecycle"`
	LifecycleReason                string   `json:"lifecycle_reason,omitempty"`
	ManifestVersion                uint64   `json:"manifest_version"`
	ManifestCoreDigest             string   `json:"manifest_core_digest,omitempty"`
	RootIssuerKeyID                string   `json:"root_issuer_key_id,omitempty"`
	RootIssuerPublicKeyFingerprint string   `json:"root_issuer_public_key_fingerprint,omitempty"`
	LaunchEnvironment              string   `json:"launch_environment,omitempty"`
	MinBinaryVersion               string   `json:"min_binary_version,omitempty"`
	Members                        []string `json:"members"`
	Revoked                        []string `json:"revoked"`
	BuyerAccounts                  []string `json:"buyer_accounts"`
	Generation                     uint64   `json:"generation"`
	RouteableGeneration            uint64   `json:"routeable_generation"`
	PubliclyAnnounced              bool     `json:"publicly_announced"`
	PublicVisibilityGeneration     uint64   `json:"public_visibility_generation"`
	PublicAnnouncementApprovalID   string   `json:"public_announcement_approval_id,omitempty"`
	PublicReviewedArtifactDigest   string   `json:"public_reviewed_distribution_artifact_digest,omitempty"`
	LastEventAtUTC                 string   `json:"last_event_at_utc,omitempty"`
	Routeable                      bool     `json:"routeable"`
	CreatorGateReason              string   `json:"creator_gate_reason,omitempty"`
	CreatorGateExpiresAtUTC        string   `json:"creator_gate_expires_at_utc,omitempty"`
	RouteGateCheckedAtUTC          string   `json:"route_gate_checked_at_utc,omitempty"`
}

func adminPoolResponse(p *ReconstructedPoolState, routeGateCheckedAt time.Time) adminPoolState {
	if p == nil {
		return adminPoolState{}
	}
	members := sortedTrueKeys(p.Members)
	revoked := sortedTrueKeys(p.Revoked)
	buyers := sortedTrueKeys(p.BuyerAccounts)
	lastEventAt := ""
	if !p.LastEventAtUTC.IsZero() {
		lastEventAt = p.LastEventAtUTC.UTC().Format(time.RFC3339Nano)
	}
	creatorGateExpiresAt := ""
	if !p.CreatorGateExpiresAtUTC.IsZero() {
		creatorGateExpiresAt = p.CreatorGateExpiresAtUTC.UTC().Format(time.RFC3339Nano)
	}
	routeGateCheckedAtRaw := ""
	if !routeGateCheckedAt.IsZero() {
		routeGateCheckedAtRaw = routeGateCheckedAt.UTC().Format(time.RFC3339Nano)
	}
	return adminPoolState{
		PoolID:                         p.PoolID,
		CreatorAccountID:               p.CreatorAccountID,
		ApprovalRecordID:               p.ApprovalRecordID,
		Lifecycle:                      p.Lifecycle,
		LifecycleReason:                p.LifecycleReason,
		ManifestVersion:                p.ManifestVersion,
		ManifestCoreDigest:             p.ManifestCoreDigest,
		RootIssuerKeyID:                rootIssuerKeyID(p),
		RootIssuerPublicKeyFingerprint: rootIssuerFingerprint(p),
		LaunchEnvironment:              rootIssuerLaunchEnvironment(p),
		MinBinaryVersion:               policyMinBinaryVersion(p),
		Members:                        members,
		Revoked:                        revoked,
		BuyerAccounts:                  buyers,
		Generation:                     p.Generation,
		RouteableGeneration:            p.RouteableSnapshotGeneration(),
		PubliclyAnnounced:              p.PubliclyAnnounced,
		PublicVisibilityGeneration:     p.PublicVisibilityGeneration,
		PublicAnnouncementApprovalID:   p.PublicAnnouncementApprovalID,
		PublicReviewedArtifactDigest:   p.PublicReviewedArtifactDigest,
		LastEventAtUTC:                 lastEventAt,
		Routeable:                      adminPoolRouteable(p),
		CreatorGateReason:              p.CreatorGateReason,
		CreatorGateExpiresAtUTC:        creatorGateExpiresAt,
		RouteGateCheckedAtUTC:          routeGateCheckedAtRaw,
	}
}

type adminHealthEvent struct {
	EventClass            string `json:"event_class"`
	Severity              string `json:"severity"`
	PoolID                string `json:"pool_id"`
	Lifecycle             string `json:"lifecycle"`
	Reason                string `json:"reason,omitempty"`
	Routeable             bool   `json:"routeable"`
	Generation            uint64 `json:"generation"`
	RouteGateCheckedAtUTC string `json:"route_gate_checked_at_utc,omitempty"`
}

func adminHealthEvents(p *ReconstructedPoolState, routeGateCheckedAt time.Time) []adminHealthEvent {
	routeable, reason := poolRouteability(p)
	severity := "info"
	eventClass := "pool_routeable"
	if !routeable {
		severity = "warning"
		eventClass = "pool_not_routeable"
	}
	checkedAt := ""
	if !routeGateCheckedAt.IsZero() {
		checkedAt = routeGateCheckedAt.UTC().Format(time.RFC3339Nano)
	}
	return []adminHealthEvent{{
		EventClass:            eventClass,
		Severity:              severity,
		PoolID:                p.PoolID,
		Lifecycle:             p.Lifecycle,
		Reason:                reason,
		Routeable:             routeable,
		Generation:            p.EffectiveGeneration(),
		RouteGateCheckedAtUTC: checkedAt,
	}}
}

type adminDistributionPackage struct {
	PackageSchemaVersion string   `json:"package_schema_version"`
	PoolID               string   `json:"pool_id"`
	CreatorAccountID     string   `json:"creator_account_id"`
	PublicDisplayName    string   `json:"public_display_name,omitempty"`
	Lifecycle            string   `json:"lifecycle"`
	LaunchEnvironment    string   `json:"launch_environment,omitempty"`
	Routeable            bool     `json:"routeable"`
	CandidateOnly        bool     `json:"candidate_only"`
	ProductionReady      bool     `json:"production_ready"`
	ManifestVersion      uint64   `json:"manifest_version"`
	ManifestCoreDigest   string   `json:"manifest_core_digest,omitempty"`
	BuyerAccounts        []string `json:"buyer_accounts"`
	Disclosures          []string `json:"disclosures"`
}

func buildAdminDistributionPackage(p *ReconstructedPoolState, state *ReconstructedState) adminDistributionPackage {
	pkg := adminDistributionPackage{
		PackageSchemaVersion: "macprovider.trustpool-distribution-package.v1",
		PoolID:               p.PoolID,
		CreatorAccountID:     p.CreatorAccountID,
		Lifecycle:            p.Lifecycle,
		LaunchEnvironment:    rootIssuerLaunchEnvironment(p),
		Routeable:            adminPoolRouteable(p),
		CandidateOnly:        true,
		ProductionReady:      false,
		ManifestVersion:      p.ManifestVersion,
		ManifestCoreDigest:   p.ManifestCoreDigest,
		BuyerAccounts:        sortedTrueKeys(p.BuyerAccounts),
		Disclosures: []string{
			"pool_id is not a bearer secret; access is credential-bound",
			"this distribution package is candidate/admin evidence and is not a production launch artifact",
			"prompts and responses are visible to the MacProvider coordinator",
			"prompts and responses may be visible to the selected provider operator",
			"this package describes a Trusted Pool, not a Privacy Pool",
		},
	}
	if state != nil {
		if approval, ok := state.CreatorApprovals[p.CreatorAccountID]; ok {
			pkg.PublicDisplayName = approval.PublicDisplayName
		}
	}
	return pkg
}

func adminPoolRouteable(p *ReconstructedPoolState) bool {
	routeable, _ := poolRouteability(p)
	return routeable
}

func rootIssuerKeyID(p *ReconstructedPoolState) string {
	if p == nil || p.RootIssuer == nil {
		return ""
	}
	return p.RootIssuer.KeyID
}

func rootIssuerFingerprint(p *ReconstructedPoolState) string {
	if p == nil || p.RootIssuer == nil {
		return ""
	}
	return p.RootIssuer.PublicKeyFingerprint
}

func rootIssuerLaunchEnvironment(p *ReconstructedPoolState) string {
	if p == nil || p.RootIssuer == nil {
		return ""
	}
	return p.RootIssuer.LaunchEnvironment
}

func sortedTrueKeys(in map[string]bool) []string {
	out := make([]string, 0, len(in))
	for k, ok := range in {
		if ok {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func writeAdminJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	envelope := map[string]any{"schema_version": AdminSchemaVersion}
	if fields, ok := payload.(map[string]any); ok {
		for k, v := range fields {
			if k == "schema_version" {
				continue
			}
			envelope[k] = v
		}
	} else {
		envelope["data"] = payload
	}
	_ = json.NewEncoder(w).Encode(envelope)
}
