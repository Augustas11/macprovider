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
// Ordering is load-bearing (see the design doc decision table): the credential
// authorization check (rows 0-4) is pure and local, so an unauthorized caller
// is rejected BEFORE any coordinator capability roundtrip (row 5) and its
// latency cannot reveal whether the named pool exists (SPEC-042-R010).
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

	// Row 4: credential authorization. Pure map lookup, no coordinator call.
	// An account absent from the config, or a pool outside its authorized set,
	// is denied with the generic non-disclosing code. The narrow-only
	// invariant is structural: the selector can only pick a pool already in
	// the ceiling, never widen it.
	if !tp.Authorizes(accountID, selector) {
		return "", errPoolUnavailable
	}

	// Defense-in-depth: never emit a header value the coordinator's opaque
	// sanitizer would drop to empty (which it would then route as GLOBAL — a
	// silent pool->global spill). Config validation already rejects such ids
	// when the feature is enabled; this guards programmatically-built configs
	// that bypass Validate().
	if !config.PoolIDHeaderSafe(selector) {
		return "", errPoolUnavailable
	}

	// Row 5: positive pool-capability negotiation. Refuse unless the assigned
	// coordinator advertises pool support; an old coordinator omits the block
	// (decoding to Enabled=false) and would otherwise route pool traffic from
	// the global snapshot (SPEC-042-R010). This uses the FRESH fetch, not the
	// 5s-cached sticky-hint metadata: a stale cached "true" would let pool
	// dispatch continue for up to the TTL after a coordinator rollback/disable
	// (trustPools==nil), and the rolled-back coordinator would ignore the
	// header and route globally — a pool->global spill the positive handshake
	// exists to prevent. A fresh check per pool-required dispatch shrinks that
	// window to the in-request TOCTOU that no gateway-side check can remove;
	// the coordinator's own member-only routing is the second line when it is
	// pool-aware. Pool traffic is opt-in, so the extra roundtrip is acceptable.
	if md, ok := s.coordinatorRoutingMetadataFresh(ctx); !ok || !md.Pools.Enabled {
		return "", errPoolUnavailable
	}

	// Row 6: authorized and capability-satisfied.
	return selector, nil
}
