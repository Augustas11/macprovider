package trustpool

import (
	"context"
	"crypto/ed25519"
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

var (
	errCreatorBoundary         = errors.New("trustpool: creator boundary mismatch")
	errCreatorProviderBoundary = errors.New("trustpool: creator provider boundary mismatch")
	errCreatorBuyerBoundary    = errors.New("trustpool: creator buyer boundary mismatch")
	errCreatorInvalidEvent     = errors.New("trustpool: invalid creator event")
)

const CreatorAdminCredentialStatusEnabled = "enabled"

type CreatorAdminCredential struct {
	CreatorAccountID string
	CredentialID     string
	Token            string
	NotBeforeUTC     time.Time
	ExpiresAtUTC     time.Time
	Status           string
}

type creatorPrincipal struct {
	CreatorID    string
	CredentialID string
}

type CreatorAdminConfigReloader interface {
	SetCreatorAdminConfig(credentials []CreatorAdminCredential, providerIDs, providerDelegatedIDs, buyerAccountIDs map[string][]string)
}

// AdminDeps wires the default-off SPEC-043 operator control surface. The
// handler accepts durable pool events only after replay-checking the whole
// history, then refreshes the live registry pointer held by the buyer server.
type AdminDeps struct {
	Store                             *Store
	Registry                          *Registry
	OperatorKey                       string
	CreatorAdminCredentials           []CreatorAdminCredential
	CreatorAdminProviderIDs           map[string][]string
	CreatorAdminProviderDelegatedIDs  map[string][]string
	CreatorAdminBuyerAccountIDs       map[string][]string
	CreatorProviderAdmitted           func(providerID string) bool
	ProviderOwnerPublicKeyForProvider func(providerID string) ([]byte, bool)
}

func NewAdminHandler(deps AdminDeps) http.Handler {
	h := &adminHandler{deps: deps}
	h.setCreatorAdminConfig(deps.CreatorAdminCredentials, deps.CreatorAdminProviderIDs, deps.CreatorAdminProviderDelegatedIDs, deps.CreatorAdminBuyerAccountIDs, false)
	return h
}

type adminHandler struct {
	deps            AdminDeps
	mu              sync.Mutex
	creatorConfigMu sync.RWMutex
}

func (h *adminHandler) SetCreatorAdminConfig(credentials []CreatorAdminCredential, providerIDs, providerDelegatedIDs, buyerAccountIDs map[string][]string) {
	h.setCreatorAdminConfig(credentials, providerIDs, providerDelegatedIDs, buyerAccountIDs, true)
}

func (h *adminHandler) setCreatorAdminConfig(credentials []CreatorAdminCredential, providerIDs, providerDelegatedIDs, buyerAccountIDs map[string][]string, liveReload bool) {
	if h == nil {
		return
	}
	h.creatorConfigMu.Lock()
	defer h.creatorConfigMu.Unlock()
	h.deps.CreatorAdminCredentials = append([]CreatorAdminCredential(nil), credentials...)
	h.deps.CreatorAdminProviderIDs = cloneStringSliceMap(providerIDs)
	h.deps.CreatorAdminProviderDelegatedIDs = cloneStringSliceMap(providerDelegatedIDs)
	h.deps.CreatorAdminBuyerAccountIDs = cloneStringSliceMap(buyerAccountIDs)
	if h.deps.Registry != nil {
		if liveReload {
			h.deps.Registry.SetCreatorAdminCeilings(providerIDs, providerDelegatedIDs, buyerAccountIDs)
		} else {
			h.deps.Registry.InitCreatorAdminCeilings(providerIDs, providerDelegatedIDs, buyerAccountIDs)
		}
	}
}

func cloneStringSliceMap(in map[string][]string) map[string][]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string][]string, len(in))
	for key, values := range in {
		out[key] = append([]string(nil), values...)
	}
	return out
}

func (h *adminHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.deps.Store == nil {
		writeAdminJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]string{"code": "unavailable"}})
		return
	}
	if strings.HasPrefix(r.URL.Path, "/creator/trust-pools/") {
		h.serveCreatorHTTP(w, r)
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
	case r.URL.Path == "/admin/trust-pools/emergency/root-compromise":
		h.handleAdminRootCompromise(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/creators/"):
		h.handleGetCreator(w, r)
	case r.URL.Path == "/admin/trust-pools/pools":
		h.handleListPools(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/reviewed-distribution-artifact"):
		h.handleReviewedDistributionArtifact(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/reviewed-artifact-lifecycle"):
		h.handleReviewedArtifactLifecycle(w, r)
	case r.URL.Path == "/admin/trust-pools/on-call-readiness":
		h.handleOnCallReadiness(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/public-announcement"):
		h.handlePublicAnnouncementApproval(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/promote"):
		h.handlePromotePoolGuarded(w, r)
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

func (h *adminHandler) serveCreatorHTTP(w http.ResponseWriter, r *http.Request) {
	principal, ok := h.creatorFromBearer(r)
	if !ok {
		writeAdminJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]string{"code": "unauthorized"}})
		return
	}
	switch {
	case r.URL.Path == "/creator/trust-pools/me":
		h.handleCreatorMe(w, r, principal.CreatorID)
	case r.URL.Path == "/creator/trust-pools/events":
		h.handleCreatorAppendEvent(w, r, principal)
	case r.URL.Path == "/creator/trust-pools/root-registration-nonces":
		h.handleCreatorIssueRootRegistrationNonce(w, r, principal)
	case r.URL.Path == "/creator/trust-pools/emergency/root-compromise":
		h.handleCreatorRootCompromise(w, r, principal)
	case r.URL.Path == "/creator/trust-pools/pools":
		h.handleCreatorListPools(w, r, principal.CreatorID)
	case strings.HasPrefix(r.URL.Path, "/creator/trust-pools/pools/") && creatorOperatorOnlyPoolRoute(r.URL.Path):
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
	case strings.HasPrefix(r.URL.Path, "/creator/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/lifecycle"):
		h.handleCreatorRestrictiveLifecycle(w, r, principal)
	case strings.HasPrefix(r.URL.Path, "/creator/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/audit"):
		h.handleCreatorPoolAudit(w, r, principal.CreatorID)
	case strings.HasPrefix(r.URL.Path, "/creator/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/health"):
		h.handleCreatorPoolHealth(w, r, principal.CreatorID)
	case strings.HasPrefix(r.URL.Path, "/creator/trust-pools/pools/") && strings.HasSuffix(r.URL.Path, "/distribution"):
		h.handleCreatorPoolDistribution(w, r, principal.CreatorID)
	case strings.HasPrefix(r.URL.Path, "/creator/trust-pools/pools/"):
		h.handleCreatorGetPool(w, r, principal.CreatorID)
	default:
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
	}
}

func (h *adminHandler) creatorFromBearer(r *http.Request) (creatorPrincipal, bool) {
	if h == nil {
		return creatorPrincipal{}, false
	}
	h.creatorConfigMu.RLock()
	credentials := append([]CreatorAdminCredential(nil), h.deps.CreatorAdminCredentials...)
	h.creatorConfigMu.RUnlock()
	if len(credentials) == 0 {
		return creatorPrincipal{}, false
	}
	sort.Slice(credentials, func(i, j int) bool {
		if credentials[i].CreatorAccountID == credentials[j].CreatorAccountID {
			return credentials[i].CredentialID < credentials[j].CredentialID
		}
		return credentials[i].CreatorAccountID < credentials[j].CreatorAccountID
	})
	now := time.Now().UTC()
	for _, credential := range credentials {
		if !auth.BearerTokenMatchesHeader(r.Header, credential.Token) {
			continue
		}
		creatorID := strings.TrimSpace(credential.CreatorAccountID)
		credentialID := strings.TrimSpace(credential.CredentialID)
		if creatorID == "" || credentialID == "" {
			return creatorPrincipal{}, false
		}
		if strings.TrimSpace(credential.Status) != CreatorAdminCredentialStatusEnabled {
			return creatorPrincipal{}, false
		}
		if credential.NotBeforeUTC.IsZero() || credential.ExpiresAtUTC.IsZero() {
			return creatorPrincipal{}, false
		}
		if now.Before(credential.NotBeforeUTC.UTC()) || !now.Before(credential.ExpiresAtUTC.UTC()) {
			return creatorPrincipal{}, false
		}
		return creatorPrincipal{CreatorID: creatorID, CredentialID: credentialID}, true
	}
	return creatorPrincipal{}, false
}

func (h *adminHandler) validateProviderOwnerPublicKeyBinding(state *ReconstructedState, e DurableEvent) error {
	if h == nil || h.deps.ProviderOwnerPublicKeyForProvider == nil {
		return ErrProviderDelegation
	}
	registered, ok := h.deps.ProviderOwnerPublicKeyForProvider(e.ProviderID)
	if !ok || len(registered) != ed25519.PublicKeySize {
		return ErrProviderDelegation
	}
	switch e.EventType {
	case EventDelegationGranted:
		submitted, err := canonicalBase64(e.ProviderOwnerPublicKey)
		if err != nil || len(submitted) != ed25519.PublicKeySize {
			return ErrProviderDelegation
		}
		if string(submitted) != string(registered) {
			return ErrProviderDelegation
		}
	case EventDelegationRevoked:
		rec, ok := state.delegationRecordFor(e.PoolID, e.DelegationID)
		if !ok || rec.Revoked {
			return ErrProviderDelegation
		}
		if string(rec.ProviderOwnerPublicKey) != string(registered) {
			return ErrProviderDelegation
		}
	default:
		return ErrProviderDelegation
	}
	return nil
}

func (h *adminHandler) creatorProviderAdmitAllowed(creatorID, providerID string) bool {
	if h == nil || creatorID == "" || providerID == "" {
		return false
	}
	h.creatorConfigMu.RLock()
	allowedProviderIDs := append([]string(nil), h.deps.CreatorAdminProviderIDs[creatorID]...)
	h.creatorConfigMu.RUnlock()
	for _, allowedProviderID := range allowedProviderIDs {
		if strings.TrimSpace(allowedProviderID) == providerID {
			return true
		}
	}
	return false
}

func (h *adminHandler) creatorProviderCurrentlyAdmitted(providerID string) bool {
	if h == nil || h.deps.CreatorProviderAdmitted == nil || providerID == "" {
		return false
	}
	return h.deps.CreatorProviderAdmitted(providerID)
}

func (h *adminHandler) creatorProviderDelegated(creatorID, providerID string) bool {
	if h == nil || creatorID == "" || providerID == "" {
		return false
	}
	h.creatorConfigMu.RLock()
	delegatedProviderIDs := append([]string(nil), h.deps.CreatorAdminProviderDelegatedIDs[creatorID]...)
	h.creatorConfigMu.RUnlock()
	for _, delegatedProviderID := range delegatedProviderIDs {
		if strings.TrimSpace(delegatedProviderID) == providerID {
			return true
		}
	}
	return false
}

func (h *adminHandler) creatorBuyerAccountAllowed(creatorID, buyerAccountID string) bool {
	if h == nil || creatorID == "" || buyerAccountID == "" {
		return false
	}
	h.creatorConfigMu.RLock()
	allowedBuyerAccountIDs := append([]string(nil), h.deps.CreatorAdminBuyerAccountIDs[creatorID]...)
	h.creatorConfigMu.RUnlock()
	for _, allowedBuyerAccountID := range allowedBuyerAccountIDs {
		if strings.TrimSpace(allowedBuyerAccountID) == buyerAccountID {
			return true
		}
	}
	return false
}

func (h *adminHandler) handleCreatorMe(w http.ResponseWriter, r *http.Request, creatorID string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
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
	if e.EventType == EventRootCompromiseFrozen {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
		return
	}
	if e.EventType == EventLifecycleChanged && e.Lifecycle == LifecycleActive {
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "activation_requires_promotion"}})
		return
	}
	if err := h.requireDeliveryDrained(e); err != nil {
		h.writeMutationError(w, err)
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

func (h *adminHandler) handleCreatorIssueRootRegistrationNonce(w http.ResponseWriter, r *http.Request, principal creatorPrincipal) {
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
	if bodyCreator := strings.TrimSpace(issue.CreatorAccountID); bodyCreator != "" && bodyCreator != principal.CreatorID {
		writeAdminJSON(w, http.StatusForbidden, map[string]any{"error": map[string]string{"code": "creator_mismatch"}})
		return
	}
	if bodyCredentialID := strings.TrimSpace(issue.CreatorCredentialID); bodyCredentialID != "" && bodyCredentialID != principal.CredentialID {
		writeAdminJSON(w, http.StatusForbidden, map[string]any{"error": map[string]string{"code": "creator_mismatch"}})
		return
	}
	operationID, err := resolveOperationID(strings.TrimSpace(issue.OperationID), r.Header)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	issue.OperationID = operationID
	issue.CreatorAccountID = principal.CreatorID
	issue.CreatorCredentialID = principal.CredentialID
	record, err := h.deps.Store.IssueRootRegistrationNonce(r.Context(), issue)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	writeAdminJSON(w, http.StatusCreated, map[string]any{"root_registration_nonce": record})
}

type rootCompromiseReport struct {
	OperationID                    string `json:"operation_id"`
	PoolID                         string `json:"pool_id"`
	RootIssuerPublicKeyFingerprint string `json:"root_issuer_public_key_fingerprint"`
}

func (h *adminHandler) handleCreatorRootCompromise(w http.ResponseWriter, r *http.Request, principal creatorPrincipal) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	var body rootCompromiseReport
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
	e := DurableEvent{
		OperationID:                    operationID,
		EventType:                      EventRootCompromiseFrozen,
		PoolID:                         strings.TrimSpace(body.PoolID),
		CreatorAccountID:               principal.CreatorID,
		CreatorCredentialID:            principal.CredentialID,
		RootIssuerPublicKeyFingerprint: strings.TrimSpace(body.RootIssuerPublicKeyFingerprint),
		Reason:                         RootCompromiseFreezeReason,
	}
	h.appendRootCompromise(w, r, e, principal.CreatorID, true)
}

func (h *adminHandler) handleAdminRootCompromise(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	var body rootCompromiseReport
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
	e := DurableEvent{
		OperationID:                    operationID,
		EventType:                      EventRootCompromiseFrozen,
		PoolID:                         strings.TrimSpace(body.PoolID),
		RootIssuerPublicKeyFingerprint: strings.TrimSpace(body.RootIssuerPublicKeyFingerprint),
		Reason:                         RootCompromiseFreezeReason,
	}
	h.appendRootCompromise(w, r, e, "", false)
}

func (h *adminHandler) appendRootCompromise(w http.ResponseWriter, r *http.Request, e DurableEvent, creatorID string, requireCreatorOwner bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	pool := state.Pools[e.PoolID]
	if pool == nil || pool.RootIssuer == nil {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	if requireCreatorOwner && pool.CreatorAccountID != creatorID {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	if e.CreatorAccountID == "" {
		e.CreatorAccountID = pool.CreatorAccountID
	}
	if e.ApprovalRecordID == "" {
		e.ApprovalRecordID = pool.ApprovalRecordID
	}
	if e.RootIssuerPublicKeyFingerprint == "" {
		e.RootIssuerPublicKeyFingerprint = pool.RootIssuer.PublicKeyFingerprint
	} else if e.RootIssuerPublicKeyFingerprint != pool.RootIssuer.PublicKeyFingerprint {
		h.writeRequestMutationError(w, ErrMalformedDurableEvent)
		return
	}
	state, committed, _, err := h.deps.Store.AppendValidatedEvent(r.Context(), e)
	if err != nil {
		h.writeRequestMutationError(w, err)
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

func (h *adminHandler) handleCreatorAppendEvent(w http.ResponseWriter, r *http.Request, principal creatorPrincipal) {
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
	e, err = normalizeCreatorEvent(r, e, principal)
	if err != nil {
		h.writeRequestMutationError(w, err)
		return
	}
	if err := creatorEventAllowed(e); err != nil {
		h.writeRequestMutationError(w, err)
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	existing, ok, err := h.deps.Store.ExistingEvent(r.Context(), e.OperationID)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	if ok {
		if e.TimestampUTC.IsZero() {
			e.TimestampUTC = existing.TimestampUTC.UTC()
		}
		if !creatorOwnsEventPool(state, existing, principal.CreatorID) {
			writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
			return
		}
		if !sameDurableEvent(existing, e) {
			h.writeRequestMutationError(w, ErrConflictingOperationID)
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
	if !creatorOwnsEventPool(state, e, principal.CreatorID) {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	if e.EventType != EventRootCompromiseFrozen && state.eventTouchesFrozenLineage(e) {
		h.writeRequestMutationError(w, ErrRootCompromiseFreeze)
		return
	}
	if err := creatorEventValidForCurrentState(state, e); err != nil {
		h.writeRequestMutationError(w, err)
		return
	}
	if e.EventType != EventRootCompromiseFrozen && !creatorApprovalValidForMutation(state, e, principal.CreatorID, time.Now().UTC()) {
		h.writeRequestMutationError(w, ErrCreatorApprovalGate)
		return
	}
	if e.EventType == EventMemberAdmitted {
		owned := h.creatorProviderAdmitAllowed(principal.CreatorID, e.ProviderID)
		delegated := h.creatorProviderDelegated(principal.CreatorID, e.ProviderID)
		if (!owned && !delegated) || !h.creatorProviderCurrentlyAdmitted(e.ProviderID) {
			h.writeRequestMutationError(w, errCreatorProviderBoundary)
			return
		}
		if delegated && !owned && strings.TrimSpace(e.DelegationID) == "" {
			h.writeRequestMutationError(w, ErrProviderDelegation)
			return
		}
	}
	if e.EventType == EventDelegationGranted || e.EventType == EventDelegationRevoked {
		if !h.creatorProviderDelegated(principal.CreatorID, e.ProviderID) || !h.creatorProviderCurrentlyAdmitted(e.ProviderID) {
			h.writeRequestMutationError(w, errCreatorProviderBoundary)
			return
		}
		if err := h.validateProviderOwnerPublicKeyBinding(state, e); err != nil {
			h.writeRequestMutationError(w, err)
			return
		}
	}
	if e.EventType == EventBuyerAuthorized || e.EventType == EventBuyerAuthorizationRm {
		if !h.creatorBuyerAccountAllowed(principal.CreatorID, e.BuyerAccountID) {
			h.writeRequestMutationError(w, errCreatorBuyerBoundary)
			return
		}
	}
	if err := h.requireDeliveryDrained(e); err != nil {
		h.writeRequestMutationError(w, err)
		return
	}
	state, committed, _, err := h.deps.Store.AppendValidatedEvent(r.Context(), e)
	if err != nil {
		h.writeRequestMutationError(w, err)
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
	if err := h.requireDeliveryDrained(e); err != nil {
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
	if err := h.requireDeliveryDrained(e); err != nil {
		h.writeMutationError(w, err)
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

func (h *adminHandler) handleCreatorRestrictiveLifecycle(w http.ResponseWriter, r *http.Request, principal creatorPrincipal) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedCreatorPath(r.URL.Path, "/lifecycle")
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
		OperationID:         operationID,
		TimestampUTC:        body.TimestampUTC,
		EventType:           EventLifecycleChanged,
		PoolID:              poolID,
		CreatorCredentialID: principal.CredentialID,
		Lifecycle:           lifecycle,
		Reason:              strings.TrimSpace(body.Reason),
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	existing, ok, err := h.deps.Store.ExistingEvent(r.Context(), e.OperationID)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	if ok {
		if e.TimestampUTC.IsZero() {
			e.TimestampUTC = existing.TimestampUTC.UTC()
		}
		if !creatorOwnsPool(state, existing.PoolID, principal.CreatorID) {
			writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
			return
		}
		if !sameDurableEvent(existing, e) {
			h.writeRequestMutationError(w, ErrConflictingOperationID)
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
	if !creatorOwnsPool(state, poolID, principal.CreatorID) {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	if err := creatorEventValidForCurrentState(state, e); err != nil {
		h.writeRequestMutationError(w, err)
		return
	}
	if !creatorApprovalValidForMutation(state, e, principal.CreatorID, time.Now().UTC()) {
		h.writeRequestMutationError(w, ErrCreatorApprovalGate)
		return
	}
	if err := h.requireDeliveryDrained(e); err != nil {
		h.writeRequestMutationError(w, err)
		return
	}
	state, committed, _, err := h.deps.Store.AppendValidatedEvent(r.Context(), e)
	if err != nil {
		h.writeRequestMutationError(w, err)
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
	CreatorCredentialID    string `json:"creator_credential_id,omitempty"`
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
SELECT operation_id, nonce, creator_account_id, creator_credential_id, approval_record_id, current_approval_version,
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
		var operationID, creatorCredentialID, consumedOperationID, consumedAt sql.NullString
		var nonce string
		if err := rows.Scan(
			&operationID,
			&nonce,
			&record.CreatorAccountID,
			&creatorCredentialID,
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
		if creatorCredentialID.Valid {
			record.CreatorCredentialID = creatorCredentialID.String
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

func (h *adminHandler) handleCreatorListPools(w http.ResponseWriter, r *http.Request, creatorID string) {
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
	for id, pool := range state.Pools {
		if pool != nil && pool.CreatorAccountID == creatorID {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	pools := make([]adminPoolState, 0, len(ids))
	for _, id := range ids {
		pools = append(pools, adminPoolResponse(state.Pools[id], state.RouteGateCheckedAt))
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"pools": pools})
}

func (h *adminHandler) handleCreatorGetPool(w http.ResponseWriter, r *http.Request, creatorID string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/creator/trust-pools/pools/"))
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
	if pool == nil || pool.CreatorAccountID != creatorID {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"pool": adminPoolResponse(pool, state.RouteGateCheckedAt)})
}

func (h *adminHandler) handleCreatorPoolAudit(w http.ResponseWriter, r *http.Request, creatorID string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedCreatorPath(r.URL.Path, "/audit")
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
	if pool == nil || pool.CreatorAccountID != creatorID {
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
	nonceAudit, err := h.rootRegistrationNonceAuditRecords(r.Context(), pool, rootRegistrationOps)
	if err != nil {
		h.writeLookupError(w, "audit_lookup_failed", err)
		return
	}
	var creatorApproval any
	if approval, ok := state.CreatorApprovals[pool.CreatorAccountID]; ok {
		creatorApproval = approval
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{
		"pool_id":                   poolID,
		"creator_approval":          creatorApproval,
		"root_registration_nonces":  nonceAudit,
		"events":                    filtered,
		"nonce_material_disclosure": "nonce digests are exported here; consumed nonce material may still appear inside root-registration durable events for replay compatibility",
	})
}

func (h *adminHandler) handleCreatorPoolHealth(w http.ResponseWriter, r *http.Request, creatorID string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedCreatorPath(r.URL.Path, "/health")
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
	if pool == nil || pool.CreatorAccountID != creatorID {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{
		"pool_id":       poolID,
		"health_events": adminHealthEvents(pool, state.RouteGateCheckedAt),
	})
}

func (h *adminHandler) handleCreatorPoolDistribution(w http.ResponseWriter, r *http.Request, creatorID string) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	poolID := poolIDFromSuffixedCreatorPath(r.URL.Path, "/distribution")
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
	if pool == nil || pool.CreatorAccountID != creatorID {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"distribution_package": buildAdminDistributionPackage(pool, state)})
}

func (h *adminHandler) writeMutationError(w http.ResponseWriter, err error) {
	h.disableRegistryOnMalformed(err)
	h.writeMutationErrorResponse(w, err)
}

func (h *adminHandler) writeRequestMutationError(w http.ResponseWriter, err error) {
	h.writeMutationErrorResponse(w, err)
}

func (h *adminHandler) writeMutationErrorResponse(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrConflictingOperationID):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "operation_conflict"}})
	case errors.Is(err, errCreatorBoundary):
		writeAdminJSON(w, http.StatusForbidden, map[string]any{"error": map[string]string{"code": "creator_mismatch"}})
	case errors.Is(err, errCreatorProviderBoundary):
		writeAdminJSON(w, http.StatusForbidden, map[string]any{"error": map[string]string{"code": "provider_not_authorized"}})
	case errors.Is(err, errCreatorBuyerBoundary):
		writeAdminJSON(w, http.StatusForbidden, map[string]any{"error": map[string]string{"code": "buyer_not_authorized"}})
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
	case errors.Is(err, ErrRootCompromiseFreeze):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "root_compromise_freeze"}})
	case errors.Is(err, ErrCreatorApprovalGate):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "creator_approval_gate_failed"}})
	case errors.Is(err, ErrPublicAnnouncementGate):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "public_announcement_gate_failed"}})
	case errors.Is(err, ErrDeliveryDrainPending):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "delivery_drain_pending"}})
	case errors.Is(err, errCreatorInvalidEvent):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
	case errors.Is(err, ErrProhibitedPromiseClaim):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "prohibited_promise_claim"}})
	case errors.Is(err, ErrProviderDelegation):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "provider_delegation_invalid"}})
	case errors.Is(err, ErrMalformedDurableEvent):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
	case errors.Is(err, ErrOnCallReadiness):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "on_call_readiness_rejected"}})
	case errors.Is(err, ErrReviewedArtifactLifecycle):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "reviewed_artifact_lifecycle_rejected"}})
	default:
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
	}
}

func (h *adminHandler) requireDeliveryDrained(e DurableEvent) error {
	if e.EventType != EventLifecycleChanged || e.Lifecycle != LifecycleRetired {
		return nil
	}
	if h == nil || h.deps.Registry == nil {
		return ErrDeliveryDrainPending
	}
	snapshot := h.deps.Registry.Snapshot(e.PoolID)
	if !snapshot.Exists || snapshot.Routeable {
		return ErrDeliveryDrainPending
	}
	if !h.deps.Registry.PoolDeliveryDrained(e.PoolID) {
		return ErrDeliveryDrainPending
	}
	return nil
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
	e.CreatorCredentialID = strings.TrimSpace(e.CreatorCredentialID)
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

func normalizeCreatorEvent(r *http.Request, e DurableEvent, principal creatorPrincipal) (DurableEvent, error) {
	bodyCreatorID := strings.TrimSpace(e.CreatorAccountID)
	bodyCredentialID := strings.TrimSpace(e.CreatorCredentialID)
	e, err := normalizeAdminEvent(r, e)
	if err != nil {
		return DurableEvent{}, err
	}
	if bodyCredentialID != "" && bodyCredentialID != principal.CredentialID {
		return DurableEvent{}, errCreatorBoundary
	}
	e.CreatorCredentialID = principal.CredentialID
	switch e.EventType {
	case EventPoolCreated, EventRootIssuerRegistered:
		if bodyCreatorID != "" && bodyCreatorID != principal.CreatorID {
			return DurableEvent{}, errCreatorBoundary
		}
		e.CreatorAccountID = principal.CreatorID
	case EventDelegationGranted, EventDelegationRevoked:
		if bodyCreatorID != "" && bodyCreatorID != principal.CreatorID {
			return DurableEvent{}, errCreatorBoundary
		}
		e.CreatorAccountID = principal.CreatorID
	default:
		if bodyCreatorID != "" && bodyCreatorID != principal.CreatorID {
			return DurableEvent{}, errCreatorBoundary
		}
		e.CreatorAccountID = ""
	}
	return e, nil
}

func creatorEventAllowed(e DurableEvent) error {
	if hasSignedControlProof(e) {
		return ErrSignedControlProofPath
	}
	switch e.EventType {
	case EventPoolCreated, EventRootIssuerRegistered, EventManifestAccepted, EventMemberAdmitted, EventMemberRevoked, EventDelegationGranted, EventDelegationRevoked, EventBuyerAuthorized, EventBuyerAuthorizationRm:
		return nil
	case EventLifecycleChanged:
		if e.Lifecycle == LifecycleActive {
			return ErrActivationRequiresPromotion
		}
		switch e.Lifecycle {
		case LifecyclePaused, LifecycleDraining, LifecycleRetired:
			return nil
		default:
			return ErrMalformedDurableEvent
		}
	default:
		return ErrMalformedDurableEvent
	}
}

func creatorOperatorOnlyPoolRoute(path string) bool {
	for _, suffix := range []string{"/promote", "/public-announcement", "/reviewed-distribution-artifact", "/signed-lifecycle"} {
		if strings.HasSuffix(path, suffix) {
			return true
		}
	}
	return false
}

func creatorOwnsEventPool(state *ReconstructedState, e DurableEvent, creatorID string) bool {
	if state == nil {
		return false
	}
	if e.EventType == EventPoolCreated {
		existing := state.Pools[e.PoolID]
		return existing == nil || existing.CreatorAccountID == creatorID
	}
	return creatorOwnsPool(state, e.PoolID, creatorID)
}

func creatorOwnsPool(state *ReconstructedState, poolID, creatorID string) bool {
	if state == nil {
		return false
	}
	pool := state.Pools[poolID]
	return pool != nil && pool.CreatorAccountID == creatorID
}

func creatorEventValidForCurrentState(state *ReconstructedState, e DurableEvent) error {
	if err := ValidateCanonicalPoolID(e.PoolID); err != nil {
		return errCreatorInvalidEvent
	}
	if state == nil {
		return errCreatorInvalidEvent
	}
	pool := state.Pools[e.PoolID]
	switch e.EventType {
	case EventPoolCreated:
		if !creatorPoolCreatedBindsIdentity(e) {
			return errCreatorInvalidEvent
		}
		if pool != nil {
			return errCreatorInvalidEvent
		}
	case EventRootIssuerRegistered:
		if pool == nil || pool.RootIssuer != nil {
			return errCreatorInvalidEvent
		}
	case EventRootCompromiseFrozen:
		if pool == nil || pool.RootIssuer == nil {
			return errCreatorInvalidEvent
		}
		if e.RootIssuerPublicKeyFingerprint != pool.RootIssuer.PublicKeyFingerprint {
			return errCreatorInvalidEvent
		}
	case EventManifestAccepted:
		if pool == nil || pool.RootIssuer == nil {
			return errCreatorInvalidEvent
		}
	case EventMemberAdmitted, EventMemberRevoked, EventDelegationGranted, EventDelegationRevoked, EventBuyerAuthorized, EventBuyerAuthorizationRm, EventLifecycleChanged:
		if pool == nil {
			return errCreatorInvalidEvent
		}
		if e.EventType == EventDelegationGranted || e.EventType == EventDelegationRevoked {
			if pool.ManifestVersion == 0 || pool.ManifestCoreDigest == "" {
				return errCreatorInvalidEvent
			}
		}
	}
	return nil
}

func creatorPoolCreatedBindsIdentity(e DurableEvent) bool {
	raw, err := canonicalBase64(e.ManifestSnapshot)
	if err != nil {
		return false
	}
	snapshot, err := poolmanifest.ParseManifestSnapshot(raw)
	if err != nil {
		return false
	}
	poolID, err := snapshot.IdentityCore.PoolID()
	if err != nil {
		return false
	}
	return poolID == e.PoolID
}

func creatorApprovalValidForMutation(state *ReconstructedState, e DurableEvent, creatorID string, now time.Time) bool {
	if state == nil || state.CreatorApprovals == nil || creatorID == "" {
		return false
	}
	approval, ok := state.CreatorApprovals[creatorID]
	if !ok {
		return false
	}
	approvalID := e.ApprovalRecordID
	version := e.CurrentApprovalVersion
	environment := e.LaunchEnvironment
	if e.EventType != EventPoolCreated && e.EventType != EventRootIssuerRegistered {
		pool := state.Pools[e.PoolID]
		if pool == nil || pool.CreatorAccountID != creatorID {
			return false
		}
		approvalID = pool.ApprovalRecordID
		if pool.RootIssuer != nil {
			version = pool.RootIssuer.CurrentApprovalVersion
			environment = pool.RootIssuer.LaunchEnvironment
		}
	}
	if version == "" {
		version = approval.CurrentApprovalVersion
	}
	if environment == "" {
		environment = approval.AllowedLaunchEnvironment
	}
	return approval.ValidFor(approvalID, version, environment, now)
}

func poolIDFromSuffixedAdminPath(path, suffix string) string {
	return poolIDFromSuffixedPath(path, "/admin/trust-pools/pools/", suffix)
}

func poolIDFromSuffixedCreatorPath(path, suffix string) string {
	return poolIDFromSuffixedPath(path, "/creator/trust-pools/pools/", suffix)
}

func poolIDFromSuffixedPath(path, prefix, suffix string) string {
	poolID := strings.TrimSpace(strings.TrimPrefix(strings.TrimSuffix(path, suffix), prefix))
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
