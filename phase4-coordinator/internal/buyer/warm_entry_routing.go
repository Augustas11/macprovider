package buyer

import (
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
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
