package trustpool

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// SPEC-043 0.3.0 self-serve private pools (#1880). An outside creator runs the
// whole pool lifecycle with its own gateway account API key: the gateway
// authenticates the key and forwards the verified principal here under the
// gateway service token. Nothing on this mount reads a configured creator
// credential or allowlist.
const (
	// LaunchEnvironmentSelfServePrivate is the only launch environment a
	// self-serve approval authorizes (SPEC-043-R001/R008 0.3.0).
	LaunchEnvironmentSelfServePrivate = "self_serve_private"
	// SelfServeApprovalActor is the approval actor of a click-through
	// Creator Agreement acceptance.
	SelfServeApprovalActor = "self_serve"

	CreatorAccountIDHeader    = "X-MacProvider-Creator-Account-ID"
	CreatorCredentialIDHeader = "X-MacProvider-Creator-Credential-ID"
	CreatorGitHubUserIDHeader = "X-MacProvider-Creator-GitHub-User-ID"

	selfServeCreatorPrefix = "/internal/creator/trust-pools/"

	// The published self-serve Creator Agreement. CurrentApprovalVersion stays
	// fixed across Agreement renewals so a renewal never strands the pools
	// bound to the approval; the Agreement version is recorded separately.
	SelfServeCreatorAgreementID      = "malibu-creator-agreement-self-serve"
	SelfServeCreatorAgreementVersion = "2026-10-09.2"
	selfServeApprovalVersion         = "self-serve-1"
	selfServePricingScheduleID       = "malibu-self-serve-pool"
	selfServePricingScheduleVersion  = "2026-10-09"
	selfServeAgreementTerm           = 365 * 24 * time.Hour
	selfServeAgreementGrace          = 30 * 24 * time.Hour
	selfServeAgreementRenewWindow    = 30 * 24 * time.Hour
	selfServeRootNonceTTL            = 15 * time.Minute
	selfServeContactMaxBytes         = 256
)

// Self-serve control-plane bounds (SPEC-043-R005 0.3.0). Every pool event is
// replayed by reconstruction, including on pool-selected chat requests, so a
// self-serve account's share of durable history is capped, and its request
// rate is limited before any lock or replay.
const (
	// SelfServeMaxPoolsPerCreator caps pool_created events per self-serve
	// account over its lifetime; retired pools still replay and still count.
	SelfServeMaxPoolsPerCreator = 8
	// SelfServeMaxPools caps self-serve pools coordinator-wide.
	SelfServeMaxPools = 256
	// SelfServeMaxEventsPerPool caps durable events per self-serve pool.
	SelfServeMaxEventsPerPool = 512
	// SelfServeRestrictiveHeadroom lets a creator pause, drain, or retire a
	// pool already at the cap: the lifecycle machine allows at most three
	// such transitions without a new (capped) promotion.
	SelfServeRestrictiveHeadroom = 8
	// SelfServeRateWindow, SelfServeMaxWritesPerWindow, and
	// SelfServeMaxRequestsPerWindow bound one account's request rate.
	SelfServeRateWindow           = time.Hour
	SelfServeMaxWritesPerWindow   = 60
	SelfServeMaxRequestsPerWindow = 600
	selfServeRateTrackedAccounts  = 10000
)

// The acknowledgment texts the coordinator hashes into the approval record.
// The creator accepts them; it cannot supply the hashes.
const (
	selfServeProhibitedClaimText  = "I will not describe this pool, in any product, marketing, resale, investor, sales, or support material, as a Privacy Pool, anonymous routing, coordinator-blind, end-to-end encrypted, confidential compute, zero-knowledge or ZK inference, dedicated or isolated compute, or compliant with HIPAA, GLBA, SOC 2, PCI-DSS, GDPR adequacy, or any other regulated-vertical regime."
	selfServeBuyerDisclosureText  = "Before or at first use I will tell every buyer I authorize that prompts and responses are visible to the Malibu coordinator and that the operator of the selected provider Mac may access request content."
	selfServeApprovalCriteriaText = "Self-serve private pool: account authenticated by its own API key, Creator Agreement accepted by click-through, launch environment self_serve_private only, never publicly announced, provider supply limited to Macs the account's GitHub identity has claimed, buyers limited to accounts the creator names."
	// SPEC-043-R013: external-runtime accountability.
	selfServeExternalRuntimeText = "A provider serving my pool through an external runtime earns only when its owner account is me (delegated membership is not available to a self-serve pool), and I am accountable for every member I admit or name in my signed member attestation; removing its attestation stops new selection at the next accepted manifest generation. External runtimes serve under administrative trust: the provider operator attests which process executes, the weights it loaded, and its token counts, and Malibu does not verify them. The runtime allowlist constrains the runtime identity the operator declares, not the executing process."
	// SPEC-043-R014: pool-model identity, price, and catalog transition.
	selfServePoolModelText = "I sign each pool model's identity and price and I am accountable for them. An entry whose artifact pair is a recommendable (priced) or blocked catalog identity is rejected; a candidate or listed catalog match keeps earning on the pool; promotion of that pair to recommendable ends the pool binding in favor of catalog pricing; removing an entry stops new routing at the next accepted generation. Artifact disclosure is exact identity provenance, not proof that the serving process loaded those bytes. Every pool model is pool-attested, not network-verified."
	// SPEC-043-R006: shared-supply limitation.
	selfServeSharedSupplyText = "My pool uses shared supply: its member Macs may also serve global traffic, and the pool has no throughput, latency, or capacity reservation guarantee. I will pass a materially equivalent disclosure to the buyers I authorize."
)

var selfServePrincipalIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$`)

var errSelfServeNotSelfServe = errors.New("trustpool: creator approval is not self-serve")

type selfServeAgreementTerms struct {
	CreatorAgreementID      string `json:"creator_agreement_id"`
	CreatorAgreementVersion string `json:"creator_agreement_version"`
	LaunchEnvironment       string `json:"launch_environment"`
	ProhibitedClaims        string `json:"prohibited_claim_acknowledgment"`
	BuyerDisclosure         string `json:"buyer_disclosure_commitment"`
	ApprovalCriteria        string `json:"approval_criteria"`
	ExternalRuntime         string `json:"external_runtime_accountability"`
	PoolModels              string `json:"pool_model_accountability"`
	SharedSupply            string `json:"shared_supply_disclosure"`
	TermDays                int    `json:"term_days"`
	GraceDays               int    `json:"grace_days"`
}

func currentSelfServeAgreementTerms() selfServeAgreementTerms {
	return selfServeAgreementTerms{
		CreatorAgreementID:      SelfServeCreatorAgreementID,
		CreatorAgreementVersion: SelfServeCreatorAgreementVersion,
		LaunchEnvironment:       LaunchEnvironmentSelfServePrivate,
		ProhibitedClaims:        selfServeProhibitedClaimText,
		BuyerDisclosure:         selfServeBuyerDisclosureText,
		ApprovalCriteria:        selfServeApprovalCriteriaText,
		ExternalRuntime:         selfServeExternalRuntimeText,
		PoolModels:              selfServePoolModelText,
		SharedSupply:            selfServeSharedSupplyText,
		TermDays:                int(selfServeAgreementTerm / (24 * time.Hour)),
		GraceDays:               int(selfServeAgreementGrace / (24 * time.Hour)),
	}
}

// SelfServeAgreementTermsDigest is SHA-256 over the JSON encoding of the
// published terms. Acceptance must echo it, so a creator accepts exactly the
// text it was shown and a later wording change cannot inherit that acceptance.
func SelfServeAgreementTermsDigest() string {
	raw, err := json.Marshal(currentSelfServeAgreementTerms())
	if err != nil {
		panic("trustpool: self-serve agreement terms do not encode: " + err.Error())
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

type selfServeAgreementRequest struct {
	CreatorAgreementVersion       string `json:"creator_agreement_version"`
	AgreementTermsDigest          string `json:"agreement_terms_digest"`
	Accept                        bool   `json:"accept"`
	PublicDisplayName             string `json:"public_display_name"`
	LegalSupportContact           string `json:"legal_support_contact"`
	BillingContact                string `json:"billing_contact"`
	EmergencyNotificationEndpoint string `json:"emergency_notification_endpoint"`
}

func (h *adminHandler) serveSelfServeCreatorHTTP(w http.ResponseWriter, r *http.Request) {
	principal, ok := h.selfServePrincipal(r)
	if !ok {
		writeAdminJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]string{"code": "unauthorized"}})
		return
	}
	write := r.Method != http.MethodGet
	if write {
		// A retry of an operation that already committed spends only the
		// request budget, so a lost response stays recoverable after the
		// write budget is used up.
		if key := strings.TrimSpace(r.Header.Get("Idempotency-Key")); key != "" {
			if _, replay, err := h.deps.Store.ExistingEvent(r.Context(), key); err != nil {
				h.writeLookupError(w, "creator_lookup_failed", err)
				return
			} else if replay {
				write = false
			}
		}
	}
	if retryAfter, ok := h.selfServeRate.allow(principal.CreatorID, write, time.Now()); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(retryAfter.Seconds())+1))
		writeAdminJSON(w, http.StatusTooManyRequests, map[string]any{"error": map[string]string{"code": "rate_limited"}})
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, selfServeCreatorPrefix)
	// Reject an unknown or foreign pool before any lock or full replay.
	if poolID, ok := selfServePathPoolID(rest); ok {
		if owned, err := h.selfServeOwnsPool(r.Context(), principal, poolID); err != nil {
			h.writeLookupError(w, "creator_lookup_failed", err)
			return
		} else if !owned {
			writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
			return
		}
	}
	switch rest {
	case "agreement":
		h.handleSelfServeAgreement(w, r, principal)
		return
	case "providers":
		h.handleSelfServeProviders(w, r, principal)
		return
	case "pricing-bounds":
		h.handleSelfServePricingBounds(w, r)
		return
	}
	// Every other operation acts under an existing approval, which must be the
	// creator's own self-serve approval: a gateway account never drives an
	// operator-approved creator's pools.
	if err := h.requireSelfServeApproval(r.Context(), principal.CreatorID); err != nil {
		if errors.Is(err, errSelfServeNotSelfServe) {
			writeAdminJSON(w, http.StatusForbidden, map[string]any{"error": map[string]string{"code": "creator_not_self_serve"}})
			return
		}
		h.writeLookupError(w, "creator_lookup_failed", err)
		return
	}
	if rest == "earnings" {
		h.handleSelfServeEarnings(w, r, principal)
		return
	}
	if strings.HasPrefix(rest, "pools/") && strings.HasSuffix(rest, "/promote") {
		h.handleSelfServePromote(w, r, principal, strings.TrimSuffix(strings.TrimPrefix(rest, "pools/"), "/promote"))
		return
	}
	rewritten := r.Clone(r.Context())
	rewritten.URL.Path = "/creator/trust-pools/" + rest
	rewritten.URL.RawPath = ""
	h.serveCreatorRoutes(w, rewritten, principal)
}

// selfServePrincipal accepts the forwarded principal only under the gateway
// service token. The headers are the gateway's verified account identity, so
// a request without the token never reaches the header parse.
func (h *adminHandler) selfServePrincipal(r *http.Request) (creatorPrincipal, bool) {
	if h == nil || strings.TrimSpace(h.deps.GatewayServiceToken) == "" {
		return creatorPrincipal{}, false
	}
	if auth.GatewayInternalBearerMatches(r.Header, h.deps.GatewayServiceToken) == auth.BearerKindNone {
		return creatorPrincipal{}, false
	}
	accountID, ok := singleHeader(r.Header, CreatorAccountIDHeader)
	if !ok || !selfServePrincipalIDPattern.MatchString(accountID) {
		return creatorPrincipal{}, false
	}
	credentialID, ok := singleHeader(r.Header, CreatorCredentialIDHeader)
	if !ok || !selfServePrincipalIDPattern.MatchString(credentialID) {
		return creatorPrincipal{}, false
	}
	principal := creatorPrincipal{CreatorID: accountID, CredentialID: credentialID, SelfServe: true}
	if values := r.Header.Values(CreatorGitHubUserIDHeader); len(values) > 0 {
		raw, ok := singleHeader(r.Header, CreatorGitHubUserIDHeader)
		if !ok {
			return creatorPrincipal{}, false
		}
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id <= 0 || strconv.FormatInt(id, 10) != raw {
			return creatorPrincipal{}, false
		}
		principal.GitHubUserID = id
	}
	return principal, true
}

func singleHeader(h http.Header, name string) (string, bool) {
	values := h.Values(name)
	if len(values) != 1 {
		return "", false
	}
	v := strings.TrimSpace(values[0])
	return v, v != "" && v == values[0]
}

func (h *adminHandler) requireSelfServeApproval(ctx context.Context, creatorID string) error {
	approval, ok, err := h.deps.Store.CreatorApproval(ctx, creatorID)
	if err != nil {
		return err
	}
	if ok && approval.ApprovedBy != SelfServeApprovalActor {
		return errSelfServeNotSelfServe
	}
	return nil
}

// handleSelfServeAgreement serves the published Agreement terms (GET) and
// records the creator's click-through acceptance (POST) as a self-serve
// approval (SPEC-043-R001 0.3.0).
// selfServePricingBoundsObject is the creator-facing view of the configured
// SPEC-005-R015 pool-model pricing bounds (#1880): inclusive credits per
// million tokens, keyed by the names a manifest rejection's `bound` uses.
// Null when the coordinator has none configured (every entry is refused).
func (h *adminHandler) selfServePricingBoundsObject() any {
	b := h.deps.Store.PoolModelPricingBounds()
	if b == nil {
		return nil
	}
	return map[string]int64{
		"min_prompt_rate_per_mtok":           b.MinPromptRatePerMtok,
		"max_prompt_rate_per_mtok":           b.MaxPromptRatePerMtok,
		"min_prompt_cache_hit_rate_per_mtok": b.MinPromptCacheHitRatePerMtok,
		"max_prompt_cache_hit_rate_per_mtok": b.MaxPromptCacheHitRatePerMtok,
		"min_completion_rate_per_mtok":       b.MinCompletionRatePerMtok,
		"max_completion_rate_per_mtok":       b.MaxCompletionRatePerMtok,
	}
}

func (h *adminHandler) handleSelfServePricingBounds(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"pool_model_pricing_bounds": h.selfServePricingBoundsObject()})
}

func (h *adminHandler) handleSelfServeAgreement(w http.ResponseWriter, r *http.Request, principal creatorPrincipal) {
	switch r.Method {
	case http.MethodGet:
		writeAdminJSON(w, http.StatusOK, map[string]any{
			"agreement":                 currentSelfServeAgreementTerms(),
			"agreement_terms_digest":    SelfServeAgreementTermsDigest(),
			"pool_model_pricing_bounds": h.selfServePricingBoundsObject(),
		})
		return
	case http.MethodPost:
	default:
		w.Header().Set("Allow", "GET, POST")
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	var body selfServeAgreementRequest
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
	if !body.Accept || body.CreatorAgreementVersion != SelfServeCreatorAgreementVersion || body.AgreementTermsDigest != SelfServeAgreementTermsDigest() {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{
			"code":                   "agreement_not_accepted",
			"current_version":        SelfServeCreatorAgreementVersion,
			"agreement_terms_digest": SelfServeAgreementTermsDigest(),
		}})
		return
	}
	for _, field := range []string{body.PublicDisplayName, body.LegalSupportContact, body.BillingContact, body.EmergencyNotificationEndpoint} {
		if strings.TrimSpace(field) == "" || len(field) > selfServeContactMaxBytes {
			writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_agreement_fields"}})
			return
		}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	now := time.Now().UTC()
	current, exists, err := h.deps.Store.CreatorApproval(r.Context(), principal.CreatorID)
	if err != nil {
		h.writeLookupError(w, "creator_lookup_failed", err)
		return
	}
	next := selfServeApproval(principal.CreatorID, principal.CredentialID, body, now)
	if exists {
		switch {
		case current.ApprovedBy != SelfServeApprovalActor:
			writeAdminJSON(w, http.StatusForbidden, map[string]any{"error": map[string]string{"code": "creator_not_self_serve"}})
			return
		case current.Status != CreatorStatusEnabled:
			writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "creator_suspended"}})
			return
		case selfServeAgreementUnchanged(current, next) && now.Add(selfServeAgreementRenewWindow).Before(current.CreatorAgreementExpiresAtUTC):
			// An exact repeat inside the term is idempotent; renewal resets
			// the term only near expiry or for a new Agreement version.
			writeAdminJSON(w, http.StatusOK, map[string]any{"creator": current})
			return
		}
		next.ApprovedAtUTC = current.ApprovedAtUTC
	}
	committed, acceptance, err := h.deps.Store.AcceptSelfServeCreatorAgreement(r.Context(), next, SelfServeAgreementTermsDigest())
	if err != nil {
		h.writeRequestMutationError(w, err)
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
	writeAdminJSON(w, http.StatusAccepted, map[string]any{"creator": committed, "acceptance": acceptance})
}

func selfServeApproval(creatorID, credentialID string, body selfServeAgreementRequest, now time.Time) CreatorApproval {
	expires := now.Add(selfServeAgreementTerm)
	return CreatorApproval{
		CreatorAccountID:                  creatorID,
		ApprovalRecordID:                  "self-serve:" + creatorID,
		CurrentApprovalVersion:            selfServeApprovalVersion,
		PublicDisplayName:                 strings.TrimSpace(body.PublicDisplayName),
		LegalSupportContact:               strings.TrimSpace(body.LegalSupportContact),
		BillingContact:                    strings.TrimSpace(body.BillingContact),
		EmergencyNotificationEndpoint:     strings.TrimSpace(body.EmergencyNotificationEndpoint),
		AcknowledgedMaxResponseTime:       "P7D",
		AllowedProductCategory:            "self_serve_private_pool",
		DataRetentionCategory:             "standard",
		SupportOwner:                      "malibu-self-serve",
		AllowedLaunchEnvironment:          LaunchEnvironmentSelfServePrivate,
		CreatorAgreementID:                SelfServeCreatorAgreementID,
		CreatorAgreementVersion:           SelfServeCreatorAgreementVersion,
		CreatorAgreementExpiresAtUTC:      expires,
		CreatorAgreementGraceEndsAtUTC:    expires.Add(selfServeAgreementGrace),
		PricingScheduleID:                 selfServePricingScheduleID,
		PricingScheduleVersion:            selfServePricingScheduleVersion,
		ProhibitedClaimAcknowledgmentHash: sha256HexString(selfServeProhibitedClaimText),
		BuyerDisclosureCommitmentHash:     sha256HexString(selfServeBuyerDisclosureText),
		ApprovalCriteriaHash:              sha256HexString(selfServeApprovalCriteriaText),
		ApprovedBy:                        SelfServeApprovalActor,
		ApprovedByCredentialID:            credentialID,
		ApprovedAtUTC:                     now,
		Status:                            CreatorStatusEnabled,
	}
}

// SelfServeRenewalPauseReason is the lifecycle reason of a pool paused by a
// self-serve Agreement renewal after the old Agreement's grace period ended.
const SelfServeRenewalPauseReason = "creator_agreement_renewal"

// SelfServeAgreementAcceptance is the append-only audit record of one
// self-serve Agreement acceptance or renewal (SPEC-043-R005 0.3.0).
type SelfServeAgreementAcceptance struct {
	CreatorAccountID        string    `json:"creator_account_id"`
	CreatorCredentialID     string    `json:"creator_credential_id"`
	CreatorAgreementID      string    `json:"creator_agreement_id"`
	CreatorAgreementVersion string    `json:"creator_agreement_version"`
	AgreementTermsDigest    string    `json:"agreement_terms_digest"`
	ApprovalRevision        uint64    `json:"approval_revision"`
	PausedPoolIDs           []string  `json:"paused_pool_ids"`
	AcceptedAtUTC           time.Time `json:"accepted_at_utc"`
}

// AcceptSelfServeCreatorAgreement records a self-serve Agreement acceptance
// or renewal in one transaction: it pauses every active pool of the creator
// that the old approval no longer authorizes but the new one would (an
// Agreement past its grace end), writes the approval, and appends the
// acceptance audit record naming the account and API key. Pausing first keeps
// SPEC-043-R011: renewal never reactivates a pool; the creator promotes it
// again. A row that already matches returns the stored approval and a zero
// acceptance without writing.
func (s *Store) AcceptSelfServeCreatorAgreement(ctx context.Context, approval CreatorApproval, termsDigest string) (CreatorApproval, SelfServeAgreementAcceptance, error) {
	if s == nil || s.db == nil {
		return CreatorApproval{}, SelfServeAgreementAcceptance{}, ErrStoreClosed
	}
	approval = normalizeCreatorApproval(approval)
	if approval.ApprovedBy != SelfServeApprovalActor || approval.ApprovedByCredentialID == "" || !validSHA256Hex(termsDigest) {
		return CreatorApproval{}, SelfServeAgreementAcceptance{}, ErrCreatorApprovalGate
	}
	if err := validateCreatorApproval(approval); err != nil {
		return CreatorApproval{}, SelfServeAgreementAcceptance{}, err
	}
	now := time.Now().UTC()
	approval.UpdatedAtUTC = now
	var committed CreatorApproval
	var acceptance SelfServeAgreementAcceptance
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		currentApprovals, err := creatorApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if err := verifyManifestAcceptanceStateFromQueryer(ctx, conn); err != nil {
			return err
		}
		current, existed := currentApprovals[approval.CreatorAccountID]
		if existed && sameCreatorApprovalExceptRevision(current, approval) {
			committed = current
			return nil
		}
		paused := []string{}
		if existed {
			paused, err = pauseSelfServePoolsForRenewal(ctx, conn, currentApprovals, current, approval, now)
			if err != nil {
				return err
			}
		}
		next, changed, err := upsertCreatorApprovalConn(ctx, conn, currentApprovals, approval, now)
		if err != nil {
			return err
		}
		committed = next
		if !changed {
			return nil
		}
		acceptance = SelfServeAgreementAcceptance{
			CreatorAccountID:        next.CreatorAccountID,
			CreatorCredentialID:     next.ApprovedByCredentialID,
			CreatorAgreementID:      next.CreatorAgreementID,
			CreatorAgreementVersion: next.CreatorAgreementVersion,
			AgreementTermsDigest:    termsDigest,
			ApprovalRevision:        next.ApprovalRevision,
			PausedPoolIDs:           paused,
			AcceptedAtUTC:           now,
		}
		pausedJSON, err := json.Marshal(paused)
		if err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO trustpool_creator_agreement_acceptances (
    creator_account_id, creator_credential_id, creator_agreement_id, creator_agreement_version,
    agreement_terms_digest, approval_revision, paused_pool_ids_json, accepted_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			acceptance.CreatorAccountID,
			acceptance.CreatorCredentialID,
			acceptance.CreatorAgreementID,
			acceptance.CreatorAgreementVersion,
			acceptance.AgreementTermsDigest,
			acceptance.ApprovalRevision,
			string(pausedJSON),
			now.Format(time.RFC3339Nano),
		)
		return err
	})
	if err != nil {
		return CreatorApproval{}, SelfServeAgreementAcceptance{}, err
	}
	return committed, acceptance, nil
}

// pauseSelfServePoolsForRenewal appends, inside the renewal transaction, a
// paused lifecycle event for each active pool of the creator whose current
// approval is invalid and which next would make valid again.
func pauseSelfServePoolsForRenewal(ctx context.Context, conn *sql.Conn, approvals map[string]CreatorApproval, current, next CreatorApproval, now time.Time) ([]string, error) {
	events, err := eventsFromQueryer(ctx, conn)
	if err != nil {
		return nil, err
	}
	state, err := reconstructEventsWithApprovals(events, approvals, now)
	if err != nil {
		return nil, err
	}
	paused := []string{}
	for id, p := range state.Pools {
		if p == nil || p.CreatorAccountID != next.CreatorAccountID || p.Lifecycle != LifecycleActive || p.RootIssuer == nil {
			continue
		}
		version, environment := p.RootIssuer.CurrentApprovalVersion, p.RootIssuer.LaunchEnvironment
		if current.ValidFor(p.ApprovalRecordID, version, environment, now) || !next.ValidFor(p.ApprovalRecordID, version, environment, now) {
			continue
		}
		paused = append(paused, id)
	}
	sort.Strings(paused)
	for _, poolID := range paused {
		e := DurableEvent{
			OperationID:         fmt.Sprintf("self_serve_renewal_pause:%s:%d:%s", next.CreatorAccountID, current.ApprovalRevision+1, poolID),
			TimestampUTC:        now,
			EventType:           EventLifecycleChanged,
			PoolID:              poolID,
			CreatorAccountID:    next.CreatorAccountID,
			CreatorCredentialID: next.ApprovedByCredentialID,
			Lifecycle:           LifecyclePaused,
			Reason:              SelfServeRenewalPauseReason,
		}
		if err := validateEvent(e); err != nil {
			return nil, err
		}
		if err := state.validateMutationCreatorGate(e, now); err != nil {
			return nil, err
		}
		if used, err := operationIDExists(ctx, conn, e.OperationID); err != nil {
			return nil, err
		} else if used {
			return nil, ErrConflictingOperationID
		}
		payload, err := json.Marshal(e)
		if err != nil {
			return nil, err
		}
		if err := insertTrustpoolEventRow(ctx, conn, e, string(payload)); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	if len(paused) > 0 {
		if _, err := reconstructEventsWithApprovals(events, approvals, now); err != nil {
			return nil, err
		}
	}
	return paused, nil
}

// SelfServeAgreementAcceptances returns a creator's acceptance audit records,
// oldest first.
func (s *Store) SelfServeAgreementAcceptances(ctx context.Context, creatorAccountID string) ([]SelfServeAgreementAcceptance, error) {
	if s == nil || s.db == nil {
		return nil, ErrStoreClosed
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT creator_account_id, creator_credential_id, creator_agreement_id, creator_agreement_version,
       agreement_terms_digest, approval_revision, paused_pool_ids_json, accepted_at_utc
FROM trustpool_creator_agreement_acceptances
WHERE creator_account_id = ?
ORDER BY id`, strings.TrimSpace(creatorAccountID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SelfServeAgreementAcceptance
	for rows.Next() {
		var a SelfServeAgreementAcceptance
		var pausedRaw, acceptedRaw string
		if err := rows.Scan(&a.CreatorAccountID, &a.CreatorCredentialID, &a.CreatorAgreementID, &a.CreatorAgreementVersion,
			&a.AgreementTermsDigest, &a.ApprovalRevision, &pausedRaw, &acceptedRaw); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(pausedRaw), &a.PausedPoolIDs); err != nil {
			return nil, fmt.Errorf("%w: agreement acceptance paused_pool_ids_json: %v", ErrMalformedDurableEvent, err)
		}
		if a.AcceptedAtUTC, err = time.Parse(time.RFC3339Nano, acceptedRaw); err != nil {
			return nil, fmt.Errorf("%w: agreement acceptance accepted_at_utc: %v", ErrMalformedDurableEvent, err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func selfServeAgreementUnchanged(current, next CreatorApproval) bool {
	return current.CreatorAgreementVersion == next.CreatorAgreementVersion &&
		current.PublicDisplayName == next.PublicDisplayName &&
		current.LegalSupportContact == next.LegalSupportContact &&
		current.BillingContact == next.BillingContact &&
		current.EmergencyNotificationEndpoint == next.EmergencyNotificationEndpoint
}

func sha256HexString(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// handleSelfServeProviders lists the providers the principal's GitHub
// identity has claimed: the SPEC-043-R006 0.3.0 self-serve ceiling.
func (h *adminHandler) handleSelfServeProviders(w http.ResponseWriter, r *http.Request, principal creatorPrincipal) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	owned, err := h.selfServeOwnedProviders(r.Context(), principal)
	if err != nil {
		h.writeLookupError(w, "provider_ownership_lookup_failed", err)
		return
	}
	type ownedProvider struct {
		ProviderID     string `json:"provider_id"`
		Admissible     bool   `json:"admissible"`
		ServingCapable bool   `json:"serving_capable"`
	}
	out := make([]ownedProvider, 0, len(owned))
	for _, id := range owned {
		out = append(out, ownedProvider{
			ProviderID:     id,
			Admissible:     h.creatorProviderAdmittedFor(principal, id),
			ServingCapable: h.creatorProviderCurrentlyAdmitted(id),
		})
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{
		"github_identity_linked": principal.GitHubUserID > 0,
		"providers":              out,
	})
}

func (h *adminHandler) selfServeOwnedProviders(ctx context.Context, principal creatorPrincipal) ([]string, error) {
	if !principal.SelfServe || principal.GitHubUserID <= 0 || h.deps.OwnedProviderIDs == nil {
		return nil, nil
	}
	return h.deps.OwnedProviderIDs(ctx, principal.GitHubUserID)
}

// creatorProviderOwned applies the principal's owned-provider ceiling: the
// ownership-claim table for a self-serve principal, the configured allowlist
// otherwise.
func (h *adminHandler) creatorProviderOwned(ctx context.Context, principal creatorPrincipal, providerID string) (bool, error) {
	if !principal.SelfServe {
		return h.creatorProviderAdmitAllowed(principal.CreatorID, providerID), nil
	}
	if providerID == "" {
		return false, nil
	}
	owned, err := h.selfServeOwnedProviders(ctx, principal)
	if err != nil {
		return false, err
	}
	for _, id := range owned {
		if id == providerID {
			return true, nil
		}
	}
	return false, nil
}

// creatorProviderAdmittedFor applies the admission-time liveness check:
// token-authenticated presence for a self-serve principal, serving
// capability otherwise.
func (h *adminHandler) creatorProviderAdmittedFor(principal creatorPrincipal, providerID string) bool {
	if principal.SelfServe && h.deps.SelfServeProviderAdmitted != nil {
		return providerID != "" && h.deps.SelfServeProviderAdmitted(providerID)
	}
	return h.creatorProviderCurrentlyAdmitted(providerID)
}

// creatorBuyerGrantAllowed applies the buyer ceiling. A self-serve creator's
// durable grant is itself the per-account authorization (SPEC-043-R007
// 0.3.0); it only needs a well-formed gateway account id.
func (h *adminHandler) creatorBuyerGrantAllowed(principal creatorPrincipal, buyerAccountID string) bool {
	if !principal.SelfServe {
		return h.creatorBuyerAccountAllowed(principal.CreatorID, buyerAccountID)
	}
	return selfServePrincipalIDPattern.MatchString(buyerAccountID)
}

// fillSelfServeNonceIssue binds a self-serve nonce to the creator's current
// approval so the CLI need not echo coordinator-fixed values back.
func (h *adminHandler) fillSelfServeNonceIssue(ctx context.Context, issue *RootRegistrationNonceIssue) error {
	approval, ok, err := h.deps.Store.CreatorApproval(ctx, issue.CreatorAccountID)
	if err != nil {
		return err
	}
	if !ok {
		return ErrCreatorApprovalGate
	}
	if strings.TrimSpace(issue.ApprovalRecordID) == "" {
		issue.ApprovalRecordID = approval.ApprovalRecordID
	}
	if strings.TrimSpace(issue.CurrentApprovalVersion) == "" {
		issue.CurrentApprovalVersion = approval.CurrentApprovalVersion
	}
	if strings.TrimSpace(issue.LaunchEnvironment) == "" {
		issue.LaunchEnvironment = approval.AllowedLaunchEnvironment
	}
	if issue.ExpiresAtUTC.IsZero() {
		issue.ExpiresAtUTC = time.Now().UTC().Add(selfServeRootNonceTTL)
	}
	return nil
}

type selfServePromotionRequest struct {
	OperationID string `json:"operation_id,omitempty"`
	Reason      string `json:"reason,omitempty"`
}

// handleSelfServePromote activates the creator's own self_serve_private pool
// through the same atomic PromotePool path operators use. validatePromotion
// applies the automated SPEC-043-R008 0.3.0 subset for that launch
// environment; any other pool answers not_found, as on the bearer surface.
func (h *adminHandler) handleSelfServePromote(w http.ResponseWriter, r *http.Request, principal creatorPrincipal, poolID string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	if poolID == "" || strings.Contains(poolID, "/") {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	var body selfServePromotionRequest
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
		h.writeRequestMutationError(w, err)
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, replay, err := h.deps.Store.ExistingEvent(r.Context(), operationID); err != nil {
		h.writeMutationError(w, err)
		return
	} else if !replay {
		var limit errSelfServeLimit
		if err := h.selfServeEventCaps(r.Context(), principal, DurableEvent{EventType: EventLifecycleChanged, PoolID: poolID, Lifecycle: LifecycleActive}); errors.As(err, &limit) {
			writeAdminJSON(w, http.StatusConflict, map[string]any{"error": map[string]string{"code": "self_serve_limit_reached", "limit": limit.limit}})
			return
		} else if err != nil {
			h.writeLookupError(w, "creator_lookup_failed", err)
			return
		}
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	pool := state.Pools[poolID]
	if pool == nil || pool.CreatorAccountID != principal.CreatorID || pool.RootIssuer == nil ||
		pool.RootIssuer.LaunchEnvironment != LaunchEnvironmentSelfServePrivate {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	state, committed, _, err := h.deps.Store.PromotePool(r.Context(), DurableEvent{
		OperationID:         operationID,
		EventType:           EventLifecycleChanged,
		PoolID:              poolID,
		CreatorAccountID:    principal.CreatorID,
		CreatorCredentialID: principal.CredentialID,
		Lifecycle:           LifecycleActive,
		Reason:              strings.TrimSpace(body.Reason),
	})
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

// CreatorEarningsQuery scopes a SPEC-043-R010 0.3.0 earnings read: the
// creator's owned providers, the creator's own pools, and an optional UTC
// day range [From, To).
type CreatorEarningsQuery struct {
	ProviderIDs []string
	PoolIDs     []string
	From        time.Time
	To          time.Time
}

// CreatorPoolEarnings is one pool's payable provider credits.
type CreatorPoolEarnings struct {
	PoolID          string `json:"pool_id"`
	PayableRequests int64  `json:"payable_requests"`
	ProviderCredits int64  `json:"provider_credits"`
}

const maxSelfServeEarningsRange = 31 * 24 * time.Hour

// handleSelfServeEarnings answers GET earnings?pool_id=&from=&to=: payable
// provider credits that the creator's claimed Macs earned on the creator's
// own pools. It is read-only provider earnings, never an executed revenue
// split; an unknown or foreign pool is not_found.
func (h *adminHandler) handleSelfServeEarnings(w http.ResponseWriter, r *http.Request, principal creatorPrincipal) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
		return
	}
	if h.deps.CreatorEarnings == nil {
		writeAdminJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]string{"code": "unavailable"}})
		return
	}
	query := r.URL.Query()
	from, to, err := parseSelfServeEarningsRange(query.Get("from"), query.Get("to"))
	if err != nil {
		writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_range"}})
		return
	}
	if poolID := strings.TrimSpace(query.Get("pool_id")); poolID != "" {
		if owned, err := h.selfServeOwnsPool(r.Context(), principal, poolID); err != nil {
			h.writeLookupError(w, "creator_lookup_failed", err)
			return
		} else if !owned {
			writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
			return
		}
	}
	state, err := h.deps.Store.Reconstruct(r.Context())
	if err != nil {
		h.writeReconstructError(w, err)
		return
	}
	var poolIDs []string
	if poolID := strings.TrimSpace(query.Get("pool_id")); poolID != "" {
		if !creatorOwnsPool(state, poolID, principal.CreatorID) {
			writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
			return
		}
		poolIDs = []string{poolID}
	} else {
		for id, pool := range state.Pools {
			if pool != nil && pool.CreatorAccountID == principal.CreatorID {
				poolIDs = append(poolIDs, id)
			}
		}
	}
	sort.Strings(poolIDs)
	owned, err := h.selfServeOwnedProviders(r.Context(), principal)
	if err != nil {
		h.writeLookupError(w, "provider_ownership_lookup_failed", err)
		return
	}
	byPool := make(map[string]CreatorPoolEarnings, len(poolIDs))
	if len(owned) > 0 && len(poolIDs) > 0 {
		rows, err := h.deps.CreatorEarnings(r.Context(), CreatorEarningsQuery{ProviderIDs: owned, PoolIDs: poolIDs, From: from, To: to})
		if err != nil {
			h.writeLookupError(w, "earnings_lookup_failed", err)
			return
		}
		for _, row := range rows {
			byPool[row.PoolID] = row
		}
	}
	pools := make([]CreatorPoolEarnings, 0, len(poolIDs))
	var totalCredits, totalRequests int64
	for _, id := range poolIDs {
		row := byPool[id]
		row.PoolID = id
		pools = append(pools, row)
		totalCredits += row.ProviderCredits
		totalRequests += row.PayableRequests
	}
	out := map[string]any{
		"creator_account_id":     principal.CreatorID,
		"owned_provider_count":   len(owned),
		"github_identity_linked": principal.GitHubUserID > 0,
		"split_execution_status": "declared_not_executed",
		"earnings_basis":         "payable_provider_credits_owned_providers",
		"pools":                  pools,
		"total_provider_credits": totalCredits,
		"total_payable_requests": totalRequests,
		"from":                   nil,
		"to":                     nil,
	}
	if !from.IsZero() {
		out["from"] = from.Format("2006-01-02")
		out["to"] = to.Format("2006-01-02")
	}
	writeAdminJSON(w, http.StatusOK, map[string]any{"earnings": out})
}

func parseSelfServeEarningsRange(fromRaw, toRaw string) (time.Time, time.Time, error) {
	if fromRaw == "" && toRaw == "" {
		return time.Time{}, time.Time{}, nil
	}
	from, err1 := time.Parse("2006-01-02", fromRaw)
	to, err2 := time.Parse("2006-01-02", toRaw)
	if err1 != nil || err2 != nil || !to.After(from) || to.Sub(from) > maxSelfServeEarningsRange {
		return time.Time{}, time.Time{}, errors.New("trustpool: invalid earnings range")
	}
	return from.UTC(), to.UTC(), nil
}

// selfServePathPoolID extracts the pool id from a pools/{id}[/...] path.
func selfServePathPoolID(rest string) (string, bool) {
	if !strings.HasPrefix(rest, "pools/") {
		return "", false
	}
	id, _, _ := strings.Cut(strings.TrimPrefix(rest, "pools/"), "/")
	return id, true
}

// selfServeOwnsPool answers from the pool_created row alone, without a lock
// or a full replay.
func (h *adminHandler) selfServeOwnsPool(ctx context.Context, principal creatorPrincipal, poolID string) (bool, error) {
	if poolID == "" {
		return false, nil
	}
	owner, ok, err := h.deps.Store.poolCreatorAccountID(ctx, poolID)
	if err != nil || !ok {
		return false, err
	}
	return owner == principal.CreatorID, nil
}

// selfServeEventOwnershipPreflight runs before the handler lock: any event on
// an existing pool must name a pool this account created, and pool_created
// must not name another account's pool.
func (h *adminHandler) selfServeEventOwnershipPreflight(ctx context.Context, principal creatorPrincipal, e DurableEvent) (bool, error) {
	owner, exists, err := h.deps.Store.poolCreatorAccountID(ctx, e.PoolID)
	if err != nil {
		return false, err
	}
	if e.EventType == EventPoolCreated {
		return !exists || owner == principal.CreatorID, nil
	}
	return exists && owner == principal.CreatorID, nil
}

// errSelfServeLimit is a self-serve durable-history cap.
type errSelfServeLimit struct{ limit string }

func (e errSelfServeLimit) Error() string { return "trustpool: self-serve limit reached: " + e.limit }

// selfServeEventCaps enforces the durable-history caps for a new (not
// replayed) self-serve event. The caller holds h.mu, so the counts and the
// append are serialized with every other control-plane write.
func (h *adminHandler) selfServeEventCaps(ctx context.Context, principal creatorPrincipal, e DurableEvent) error {
	limit := SelfServeMaxEventsPerPool
	if e.EventType == EventLifecycleChanged && e.Lifecycle != "" && e.Lifecycle != LifecycleActive {
		limit += SelfServeRestrictiveHeadroom
	}
	if e.EventType == EventPoolCreated {
		creatorPools, allPools, err := h.deps.Store.selfServePoolCounts(ctx, principal.CreatorID)
		if err != nil {
			return err
		}
		if creatorPools >= SelfServeMaxPoolsPerCreator {
			return errSelfServeLimit{limit: "pools_per_creator"}
		}
		if allPools >= SelfServeMaxPools {
			return errSelfServeLimit{limit: "self_serve_pools"}
		}
		return nil
	}
	events, err := h.deps.Store.poolEventCount(ctx, e.PoolID)
	if err != nil {
		return err
	}
	if events >= limit {
		return errSelfServeLimit{limit: "events_per_pool"}
	}
	return nil
}

func (s *Store) poolCreatorAccountID(ctx context.Context, poolID string) (string, bool, error) {
	if s == nil || s.db == nil {
		return "", false, ErrStoreClosed
	}
	var owner sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT creator_account_id FROM trustpool_events
WHERE pool_id = ? AND event_type = ?
ORDER BY id LIMIT 1`, poolID, EventPoolCreated).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return owner.String, true, nil
}

func (s *Store) selfServePoolCounts(ctx context.Context, creatorAccountID string) (int, int, error) {
	if s == nil || s.db == nil {
		return 0, 0, ErrStoreClosed
	}
	var creatorPools, allPools int
	if err := s.db.QueryRowContext(ctx, `
SELECT COUNT(*) FROM trustpool_events WHERE creator_account_id = ? AND event_type = ?`, creatorAccountID, EventPoolCreated).Scan(&creatorPools); err != nil {
		return 0, 0, err
	}
	if err := s.db.QueryRowContext(ctx, `
SELECT COUNT(*) FROM trustpool_events WHERE event_type = ? AND approval_record_id LIKE 'self-serve:%'`, EventPoolCreated).Scan(&allPools); err != nil {
		return 0, 0, err
	}
	return creatorPools, allPools, nil
}

func (s *Store) poolEventCount(ctx context.Context, poolID string) (int, error) {
	if s == nil || s.db == nil {
		return 0, ErrStoreClosed
	}
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM trustpool_events WHERE pool_id = ?`, poolID).Scan(&n)
	return n, err
}

// selfServeRateLimiter is a per-account fixed-window limiter. It is
// process-local: one coordinator serves the control plane.
type selfServeRateLimiter struct {
	mu       sync.Mutex
	accounts map[string]*selfServeRateWindow
}

type selfServeRateWindow struct {
	start    time.Time
	requests int
	writes   int
}

func newSelfServeRateLimiter() *selfServeRateLimiter {
	return &selfServeRateLimiter{accounts: make(map[string]*selfServeRateWindow)}
}

// allow counts one request (and one write when write is true) for account
// and reports the wait until the window resets when a budget is spent.
func (l *selfServeRateLimiter) allow(account string, write bool, now time.Time) (time.Duration, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	win := l.accounts[account]
	if win == nil || now.Sub(win.start) >= SelfServeRateWindow {
		if win == nil && len(l.accounts) >= selfServeRateTrackedAccounts {
			for id, old := range l.accounts {
				if now.Sub(old.start) >= SelfServeRateWindow {
					delete(l.accounts, id)
				}
			}
		}
		win = &selfServeRateWindow{start: now}
		l.accounts[account] = win
	}
	if win.requests >= SelfServeMaxRequestsPerWindow || (write && win.writes >= SelfServeMaxWritesPerWindow) {
		return win.start.Add(SelfServeRateWindow).Sub(now), false
	}
	win.requests++
	if write {
		win.writes++
	}
	return 0, true
}
