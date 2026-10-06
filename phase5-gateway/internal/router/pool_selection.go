package router

import (
	"context"
	"net/http"
	"strings"

	"github.com/augstar/macprovider-gateway/internal/config"
)

const (
	// poolSelectHeader is the inbound buyer-facing pool selector header. It is
	// deliberately DISTINCT from poolEmitHeader so a buyer can never smuggle
	// the internal authority header (copyForwardHeaders already allowlists only
	// Accept / X-MacProvider-Retry / Idempotency-Key, so neither is forwarded
	// verbatim — the gateway sets the outbound one explicitly).
	poolSelectHeader = "X-MacProvider-Pool-Select"
	// poolEmitHeader is the outbound authority header the coordinator honors
	// (only under the gateway service-token bearer + authenticated account).
	poolEmitHeader = "X-MacProvider-Pool"
)

// poolSelectionError is a typed pool-resolution rejection the handler maps to
// writeError. Kept separate from the http layer so resolvePoolSelection stays
// unit-testable.
type poolSelectionError struct {
	status  int
	typ     string
	code    string
	message string
}

var (
	// errPoolUnavailable is the single generic, non-disclosing rejection for
	// EVERY pool-denial cause (feature disabled, unauthorized, unknown pool,
	// coordinator without pool support). One fixed (503, non-retryable, same
	// code/type) response so neither status, code, nor the derived retryable
	// flag distinguishes cause and reveals private-pool existence
	// (SPEC-042-R010).
	errPoolUnavailable = &poolSelectionError{
		status:  http.StatusServiceUnavailable,
		typ:     "service_unavailable",
		code:    "pool_unavailable",
		message: "Pool unavailable",
	}
	// errPoolSelectionInvalid is returned ONLY for a syntactically conflicting
	// selection (the selector header supplied more than once with different
	// values). It never fires on an out-of-scope pool (that is
	// errPoolUnavailable), so the 400 cannot confirm a pool exists
	// (SPEC-042-R010).
	errPoolSelectionInvalid = &poolSelectionError{
		status:  http.StatusBadRequest,
		typ:     "invalid_request_error",
		code:    "pool_selection_invalid",
		message: "Conflicting pool selection",
	}
)

// resolvePoolSelection resolves the SPEC-042 pool for a chat request and
// authorizes it against the request's credential (account granularity) and the
// coordinator's advertised capability. The selector is a control-plane HTTP
// header (poolSelectHeader) only — deliberately NOT a request-body field, so
// the data-plane body forwarded to the coordinator/provider carries no pool
// control metadata. It returns:
//
//   - ("", nil)        global (poolless) routing — emit no pool header, the
//     byte-identical default (no selector, or feature off with
//     no selector);
//   - (poolID, nil)    an authorized, capability-satisfied pool to emit;
//   - ("", selErr)     a typed rejection.
//
// Ordering is load-bearing: every pool-selected request performs the same
// selector-independent /internal/routing refresh before any authorization or
// routeability check, so latency cannot reveal whether the named pool exists
// or why it was refused (SPEC-042-R010, SPEC-043-R007). Static account_pools
// mode authorizes from config; SPEC-043 creator self-service deployments may
// opt into coordinator_authorizes, which also accepts the coordinator's
// account->pool projection. The selector is evaluated locally in both modes
// and only then emitted as the internal authority header.
func (s *Server) resolvePoolSelection(ctx context.Context, headers http.Header, accountID string, poolSelectionAllowed bool) (string, *poolSelectionError) {
	tp := s.cfg.Features.TrustedPools

	// Collect the distinct non-empty selector values. Multiple header values
	// naming different pools is an ambiguous/conflicting selection.
	var selector string
	conflicting := false
	for _, raw := range headers.Values(poolSelectHeader) {
		v := strings.TrimSpace(raw)
		if v == "" {
			continue
		}
		if selector == "" {
			selector = v
		} else if v != selector {
			conflicting = true
		}
	}

	// Row 0: the auth mode must be permitted to select a pool. Only plain
	// API-key credentials may. Wallet sessions (SPEC-040) MUST NOT select a
	// pool until the wallet semantic signature covers pool_id + the manifest
	// digest (SPEC-042-R002 explicit deferral) — the selector header is not in
	// the signed profile, so honoring it would authorize a pool with no signed
	// binding. Demo traffic has no durable account scope. Presenting a selector
	// is rejected with the generic non-disclosing code, before authorization or
	// the conflict check, so it also does not reveal pool existence.
	if !poolSelectionAllowed && selector != "" {
		return "", errPoolUnavailable
	}

	// Row 1: conflicting selection sources (multiple distinct header values).
	if conflicting {
		return "", errPoolSelectionInvalid
	}

	// Row 2: no selection -> global, byte-identical.
	if selector == "" {
		return "", nil
	}

	// Row 3: a pool is named but the feature is off. Fail closed rather than
	// silently downgrade a pool request to global (SPEC-042-R002 forbids the
	// silent pool->global reassignment); this is also the rollback behavior
	// when pool config is disabled.
	if !tp.Enabled {
		return "", errPoolUnavailable
	}

	// Defense-in-depth: never emit a header value the coordinator's opaque
	// sanitizer would drop to empty (which it would then route as GLOBAL — a
	// silent pool->global spill). Config validation already rejects such ids
	// when the feature is enabled; this guards programmatically-built configs
	// that bypass Validate().
	if !config.PoolIDHeaderSafe(selector) || !config.PoolIDBase64URLShape(selector) || !config.PoolIDCanonicalShape(selector) {
		return "", errPoolUnavailable
	}

	// Row 4: credential authorization. Every pool-selected request, in both
	// modes and for every selector, first refreshes the service-token protected
	// /internal/routing projection and only then evaluates every check locally,
	// so unknown, unauthorized, paused/draining/retired/created,
	// candidate-blocked and creator-agreement-expired selections all perform the
	// identical lookup and share one floored rejection (SPEC-043-R007). A
	// rejection that returned before the fetch would be faster than one that
	// returned after it by up to the fetch latency, which the timing floor cannot
	// hide once that latency exceeds the floor. The request-specific selector is
	// never sent to the coordinator. Static mode authorizes from config only;
	// coordinator-authorized mode also accepts creator-authored buyer scopes.
	md, ok := s.coordinatorRoutingMetadataFresh(ctx)
	authorized := tp.Authorizes(accountID, selector)
	if tp.CoordinatorAuthorizes && ok && md.Pools.Authorizes(accountID, selector) {
		authorized = true
	}
	routeable := ok && md.Pools.Enabled && md.Pools.Routeable(selector)
	if !authorized || !routeable {
		return "", errPoolUnavailable
	}

	// Row 5: authorized and capability-satisfied. The fresh positive
	// pool-capability negotiation happened above in both modes; an old coordinator
	// omits pools.enabled and fails closed before this return.
	return selector, nil
}
