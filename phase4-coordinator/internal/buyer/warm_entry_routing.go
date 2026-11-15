package buyer

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"golang.org/x/text/unicode/norm"
)

// servedModelHeader carries served_model_id on an HTTP-forwarded dispatch
// (SPEC-001-R016 Request routing).
const servedModelHeader = "X-MacProvider-Served-Model"

// servedModelKey is the SPEC-010 case-folded served model id.
func servedModelKey(modelID string) string {
	return strings.ToLower(norm.NFC.String(modelID))
}

// furtherWarmEntry reports whether p is the per-entry view of a warm-set
// member other than the primary (SPEC-002-R011). Such an entry has seats of
// its own; the primary's seats are the session's.
func furtherWarmEntry(p pool.Provider) bool {
	if p.ServedModelID == "" {
		return false
	}
	key := servedModelKey(p.ServedModelID)
	for _, m := range p.WarmModels {
		if m.Primary && servedModelKey(m.ModelID) == key {
			return false
		}
	}
	return true
}

// slotKey is the slot-queue key of a routing candidate. A provider without a
// warm set and the primary entry of one keep the provider id, so plaintext,
// relay-blind and privacy-class reservations on the primary's seats share
// one queue. A further member is keyed by provider and served model, so a
// waiter for one member is never granted another member's seat.
func slotKey(p pool.Provider) string {
	if !furtherWarmEntry(p) {
		return p.ProviderID
	}
	return p.ProviderID + "#" + servedModelKey(p.ServedModelID)
}

// resolveSlotKey resolves the live entry a slot key names.
func (s *Server) resolveSlotKey(key string) (pool.Provider, bool) {
	providerID, servedModel, _ := strings.Cut(key, "#")
	return s.pool.ResolveEntry(providerID, "", servedModel)
}

// sameServedEntry reports whether a and b name the same entry of one
// provider; for providers without a warm set it is a provider-id compare.
func sameServedEntry(a, b pool.Provider) bool {
	return a.ProviderID == b.ProviderID && servedModelKey(a.ServedModelID) == servedModelKey(b.ServedModelID)
}

// pinnedEntries keeps one entry per provider for the pin paths: the entry
// serving the requested model when the provider keeps a warm set and has it,
// otherwise the provider's primary entry, which then fails the model check
// exactly as a pin to a provider serving another model does. Providers
// without a warm set pass through unchanged.
func (s *Server) pinnedEntries(providers []pool.Provider, model string, class *config.ModelClassConfig) []pool.Provider {
	chosen := map[string]int{}
	out := make([]pool.Provider, 0, len(providers))
	for _, p := range providers {
		if p.ServedModelID == "" {
			out = append(out, p)
			continue
		}
		key := p.ProviderID + "/" + p.AssignedID
		i, seen := chosen[key]
		switch {
		case !seen:
			chosen[key] = len(out)
			out = append(out, p)
		case !s.providerMatchesRequest(out[i], model, class) && s.providerMatchesRequest(p, model, class):
			out[i] = p
		}
	}
	return out
}

// setServedModelHeader names the chosen entry on an HTTP-forwarded dispatch.
// A provider without a warm set gets no header.
func setServedModelHeader(h http.Header, p pool.Provider) {
	if p.ServedModelID != "" {
		h.Set(servedModelHeader, p.ServedModelID)
	}
}

// entryNotLoadedErrorCode is the SPEC-001 end status of a model_not_loaded
// answer; the request log records it so the attempt carries null usage.
const entryNotLoadedErrorCode = "error_model_not_loaded"

// entryModelNotLoaded reports a provider's model_not_loaded answer to a
// dispatch that named a warm-set entry (SPEC-001-R016 Request routing): a
// preflight_ack reason, a WS end status or an HTTP error code. A provider
// without a warm set never gets an entry view, so its answer keeps today's
// handling.
func entryModelNotLoaded(p pool.Provider, code string) bool {
	if p.ServedModelID == "" {
		return false
	}
	return code == entryNotLoadedErrorCode || code == string(providerws.PreflightRejectionModelNotLoaded)
}

// markEntryNotLoaded closes the entry until its next heartbeat. It is never a
// breaker fault and never touches the session or its other entries.
func (s *Server) markEntryNotLoaded(p pool.Provider, requestID string) {
	if s.pool == nil || !s.pool.MarkEntryNotLoaded(p.ProviderID, p.AssignedID, p.ServedModelID) {
		return
	}
	s.log.Warn().
		Str("event", "warm_entry_model_not_loaded").
		Str("provider_id", p.ProviderID).
		Str("served_model_id", p.ServedModelID).
		Str("request_id", requestID).
		Msg("warm-set entry answered model_not_loaded; unavailable until its next heartbeat")
}

// httpProviderErrorCode is the error.code of a provider's JSON error body.
func httpProviderErrorCode(body []byte) string {
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return ""
	}
	return envelope.Error.Code
}

// noProviderForModelRouteError is the answer for a model no provider can
// serve, given once every entry that answered model_not_loaded is excluded.
func noProviderForModelRouteError(model string) *routeError {
	return &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "No provider available for model " + model}
}
