package buyer

import (
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-006-R016 / SPEC-042-R014 (#1690 M7): buyer engine selection. The
// gateway carries the buyer's selector as a runtime class; the coordinator
// filters candidates by the runtime class it records and discloses the class
// that served.
const (
	engineInternalHeader = "X-MacProvider-Internal-Engine"
	engineResponseHeader = "X-MacProvider-Engine"
	engineClassNative    = "mlx_cache"
)

func validEngineClass(class string) bool {
	switch class {
	case engineClassNative, "llamacpp_loopback", "mlxlm_loopback", "ollama_loopback":
		return true
	default:
		return false
	}
}

// internalEngineSelection reads X-MacProvider-Internal-Engine. ok is false for
// a value outside the closed runtime classes or two distinct values; "" with
// ok means no selection.
func internalEngineSelection(headers http.Header) (string, bool) {
	var class string
	for _, raw := range headers.Values(engineInternalHeader) {
		v := strings.TrimSpace(raw)
		if v == "" {
			continue
		}
		if !validEngineClass(v) || (class != "" && v != class) {
			return "", false
		}
		class = v
	}
	return class, true
}

// providerEngineClass is the runtime class the engine filter and the
// X-MacProvider-Engine disclosure read (SPEC-042-R004). A loopback session is
// selectable only after the R004 predicate proves its hello value equals the
// class recorded on its signed offer, so on every path that can select it
// the hello value is the coordinator-recorded class. Every other session is
// native and eligible only through the native rules.
func providerEngineClass(p pool.Provider) string {
	if providerws.IsBYOMLoopbackRuntimeSource(p.RuntimeSource) {
		return p.RuntimeSource
	}
	return engineClassNative
}

// externalRuntimeNeedsSignedFinalityMessage names why a pool route withheld
// its external-runtime members: the caller did not negotiate signed
// settlement finality (SPEC-022 R-12.8, E2E-F10).
const externalRuntimeNeedsSignedFinalityMessage = "External-runtime pool members serve only through a gateway that negotiates signed settlement finality"

func engineUnavailableRouteError(message string) *routeError {
	return &routeError{status: http.StatusServiceUnavailable, code: "engine_unavailable", message: message}
}

// engineRouteError is SPEC-042-R014 (a): a non-native class needs a pool
// route whose active allowlist contains it. native is always routeable.
func engineRouteError(engineClass string, poolActive bool, runtimeAllowlist []string) *routeError {
	if engineClass == "" || engineClass == engineClassNative {
		return nil
	}
	if !poolActive {
		return engineUnavailableRouteError("Selected engine is available only on a Trusted Pool route that allows it")
	}
	for _, allowed := range runtimeAllowlist {
		if allowed == engineClass {
			return nil
		}
	}
	return engineUnavailableRouteError("Selected engine is not allowed by the selected pool")
}

// providersForEngine keeps only the sessions of the selected class, so the
// candidate and slot-queue passes never see another engine.
func providersForEngine(providers []pool.Provider, engineClass string) []pool.Provider {
	out := make([]pool.Provider, 0, len(providers))
	for _, p := range providers {
		if providerEngineClass(p) == engineClass {
			out = append(out, p)
		}
	}
	return out
}

// engineServesModelInScope is SPEC-042-R014 (d): whether any session of the
// selected class in the route's scope (the pool's members, or every session
// on a global route) serves the requested model at all.
func (s *Server) engineServesModelInScope(providers []pool.Provider, model string, class *config.ModelClassConfig, poolActive bool, members map[string]bool) bool {
	for _, p := range providers {
		if poolActive && !members[p.ProviderID] {
			continue
		}
		if s.providerMatchesRequest(p, model, class) {
			return true
		}
	}
	return false
}
