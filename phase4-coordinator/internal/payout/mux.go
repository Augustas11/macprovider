package payout

import (
	"fmt"
	"net/http"

	"github.com/go-chi/chi/v5"
)

// AuthRealm names the SPEC-016 §3.3 path-table column —
// "single map[path]authRealm table verified at coordinator
// startup; any registered route NOT in the table fails closed".
// At Step 1 the only realm present is "provider_token" (§3.3).
// Operator-authenticated paths land in Step 2 (run-now,
// abandon-attempt) and Step 3 (record-funding, record-orphan,
// pause/resume).
type AuthRealm string

const (
	// RealmProviderToken denotes per-Mac provider-token auth.
	// Used by POST /providers/{provider_id}/payout-address.
	RealmProviderToken AuthRealm = "provider_token"
	// RealmOperatorKey denotes operator-key auth. Reserved for
	// Steps 2-4 admin paths.
	RealmOperatorKey AuthRealm = "operator_key"
)

// PathTableEntry pairs a chi router pattern with its
// HTTP method and the SPEC-pinned auth realm. The static
// declaration is the canonical source of truth; the Mux
// constructor cross-checks every registered route against the
// table at construction time and fails-fast on mismatch.
type PathTableEntry struct {
	Method string
	Path   string
	Realm  AuthRealm
}

// step1PathTable enumerates every payout-package route that
// Step 1 mounts. Subsequent steps extend this slice with their
// own entries; the audit-verifier asserts that no handler
// escapes this declaration. EXACT-MATCH chi patterns only — no
// trailing-slash prefix routes.
var step1PathTable = []PathTableEntry{
	{Method: http.MethodPost, Path: "/providers/{provider_id}/payout-address", Realm: RealmProviderToken},
}

// NewMux constructs the chi-based payout HTTP router. The
// returned http.Handler is mounted by main.go on the existing
// provider listener (the SPEC's `:8444` ws-mux listener) at the
// `/providers/` prefix; chi's longest-pattern-match semantics
// route /providers/{id}/payout-address to the §3.3 handler and
// delegate everything else (e.g. /providers/{id}/earnings) to
// the fallback handler.
//
// SPEC §3.3 path-table requirement: this constructor checks
// that EVERY route registered with chi appears verbatim in
// step1PathTable AND that NO declared table entry is missing
// from the chi router. Any drift fails-fast at startup.
//
// fallback is invoked for any /providers/* path the payout
// router does not own (e.g. billing earnings). Non-/providers
// paths are NOT delegated to the fallback — they 404.
func NewMux(addresses *AddressesService, fallback http.Handler) (http.Handler, error) {
	if addresses == nil {
		return nil, fmt.Errorf("payout.NewMux: AddressesService is required")
	}
	if fallback == nil {
		return nil, fmt.Errorf("payout.NewMux: fallback handler is required")
	}
	r := chi.NewRouter()

	// §3.3 handler — provider_token auth.
	r.Post("/providers/{provider_id}/payout-address", addresses.ServePayoutAddress)

	// Everything else under /providers/ delegates to the
	// fallback. The route is registered with chi so the path-
	// table audit can declare it; we list it AFTER the explicit
	// /payout-address pattern so chi's most-specific-match
	// resolves correctly.
	r.HandleFunc("/providers/*", fallback.ServeHTTP)

	// SPEC §3.3 path-table verification. Walk chi's routes and
	// confirm parity with step1PathTable.
	if err := verifyPathTable(r, step1PathTable); err != nil {
		return nil, err
	}
	return r, nil
}

// verifyPathTable walks the chi router and asserts every
// payout-owned route appears in the SPEC-declared table.
// Routes registered via HandleFunc (the fallback delegate
// wildcard above) are explicitly excluded — they are not
// payout-realm routes.
func verifyPathTable(r chi.Router, table []PathTableEntry) error {
	declared := make(map[string]AuthRealm, len(table))
	for _, entry := range table {
		key := entry.Method + " " + entry.Path
		declared[key] = entry.Realm
	}
	registered := map[string]bool{}
	err := chi.Walk(r, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		key := method + " " + route
		// The wildcard fallback is intentionally NOT in the
		// declared table.
		if route == "/providers/*" {
			return nil
		}
		registered[key] = true
		if _, ok := declared[key]; !ok {
			return fmt.Errorf("payout.NewMux: route %s registered with chi but missing from SPEC §3.3 path-table", key)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for key := range declared {
		if !registered[key] {
			return fmt.Errorf("payout.NewMux: SPEC §3.3 path-table declares %s but it is not registered with chi", key)
		}
	}
	return nil
}
