package trustpool

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
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
	if !auth.OperatorOnlyBearerMatches(r.Header, h.deps.OperatorKey) {
		writeAdminJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]string{"code": "unauthorized"}})
		return
	}
	if h.deps.Store == nil {
		writeAdminJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]string{"code": "unavailable"}})
		return
	}
	switch {
	case r.URL.Path == "/admin/trust-pools/events":
		h.handleAppendEvent(w, r)
	case r.URL.Path == "/admin/trust-pools/creators":
		h.handleUpsertCreator(w, r)
	case strings.HasPrefix(r.URL.Path, "/admin/trust-pools/creators/"):
		h.handleGetCreator(w, r)
	case r.URL.Path == "/admin/trust-pools/pools":
		h.handleListPools(w, r)
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
		writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "reconstruct_failed"}})
		return
	}
	if h.deps.Registry != nil {
		if state.Revision > h.deps.Registry.Revision() {
			if err := h.deps.Registry.LoadRouteableSnapshotsAtRevision(state.Revision, state.RouteableSnapshots()); err != nil {
				writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "registry_refresh_failed"}})
				return
			}
		}
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
		writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "creator_lookup_failed"}})
		return
	}
	if !ok {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"creator": approval})
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
	state, committed, applied, err := h.deps.Store.AppendValidatedEvent(r.Context(), e)
	if err != nil {
		h.writeMutationError(w, err)
		return
	}
	if h.deps.Registry != nil && applied {
		if err := h.deps.Registry.LoadRouteableSnapshotsAtRevision(state.Revision, state.RouteableSnapshots()); err != nil {
			writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "registry_refresh_failed"}})
			return
		}
	}
	writeAdminJSON(w, http.StatusAccepted, map[string]any{
		"event": committed,
		"pool":  adminPoolResponse(state.Pools[committed.PoolID], state.RouteGateCheckedAt),
	})
}

func (h *adminHandler) handleListPools(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "reconstruct_failed"}})
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
		writeAdminJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "reconstruct_failed"}})
		return
	}
	pool := state.Pools[poolID]
	if pool == nil {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"pool": adminPoolResponse(pool, state.RouteGateCheckedAt)})
}

func (h *adminHandler) writeMutationError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrConflictingOperationID):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "operation_conflict"}})
	case errors.Is(err, ErrActivationRequiresPromotion):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "activation_requires_promotion"}})
	case errors.Is(err, ErrRootRegistrationNonce):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_root_registration_nonce"}})
	case errors.Is(err, ErrCreatorApprovalGate):
		writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "creator_approval_gate_failed"}})
	case errors.Is(err, ErrMalformedDurableEvent):
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
	default:
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_event"}})
	}
}

func normalizeAdminEvent(r *http.Request, e DurableEvent) (DurableEvent, error) {
	bodyOperationID := strings.TrimSpace(e.OperationID)
	idempotencyKey := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	legacyOperationID := strings.TrimSpace(r.Header.Get("X-Operation-ID"))
	operationID := bodyOperationID
	for _, candidate := range []string{idempotencyKey, legacyOperationID} {
		if candidate == "" {
			continue
		}
		if operationID == "" {
			operationID = candidate
			continue
		}
		if operationID != candidate {
			return DurableEvent{}, ErrConflictingOperationID
		}
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
		MinBinaryVersion:               p.MinBinaryVersion,
		Members:                        members,
		Revoked:                        revoked,
		BuyerAccounts:                  buyers,
		Generation:                     p.Generation,
		RouteableGeneration:            p.RouteableSnapshotGeneration(),
		LastEventAtUTC:                 lastEventAt,
		Routeable:                      p.Lifecycle == LifecycleActive && p.CreatorGateReason == "",
		CreatorGateReason:              p.CreatorGateReason,
		CreatorGateExpiresAtUTC:        creatorGateExpiresAt,
		RouteGateCheckedAtUTC:          routeGateCheckedAtRaw,
	}
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
