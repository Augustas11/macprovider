package ws

import (
	"strings"
	"sync"
	"time"

	"golang.org/x/text/unicode/norm"
)

// AuthAttemptState retains the per-attempt SPEC-010 v1.5 R-3.1.10
// values across the v2 auth_request initial->proof handshake.
// Populated only when at least one of supported_models /
// publishes_supported_models is present on the initial-stage frame
// (R-7.9.8 L-1 baseline gate).
type AuthAttemptState struct {
	AuthAttemptID            string
	ProviderID               string
	SupportedModels          []string
	PublishesSupportedModels bool
	SupportedModelsPresent   bool // initial-stage carried supported_models key
	PublishesPresent         bool // initial-stage carried publishes_supported_models key
	StartedAt                time.Time
	ExpiresAt                time.Time
}

// authAttemptStore implements the §7.9 lifecycle with a max-bound
// defensive cap per R-7.9.6. Concurrent-safe via a single mutex.
type authAttemptStore struct {
	mu       sync.Mutex
	entries  map[string]AuthAttemptState
	maxBound int
}

func newAuthAttemptStore(maxBound int) *authAttemptStore {
	if maxBound <= 0 {
		maxBound = 1024
	}
	return &authAttemptStore{
		entries:  make(map[string]AuthAttemptState),
		maxBound: maxBound,
	}
}

// tryReserve attempts to insert a new retention entry. Returns
// false if the store is at maxBound — caller MUST reject the
// initial-stage frame BEFORE creating any other state, per
// R-7.9.6 and AC-K.16 ("rejection MUST occur BEFORE creating a
// new retention entry").
func (s *authAttemptStore) tryReserve(state AuthAttemptState) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.entries) >= s.maxBound {
		return false
	}
	s.entries[state.AuthAttemptID] = state
	return true
}

// release removes a retention entry. Safe to call on an unknown
// ID (the defer pattern in the server may release after the
// proof-stage acceptance has already cleared it).
func (s *authAttemptStore) release(authAttemptID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.entries, authAttemptID)
}

// lookup returns a copy of the retention entry for the given ID
// and a boolean indicating whether it was found.
func (s *authAttemptStore) lookup(authAttemptID string) (AuthAttemptState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.entries[authAttemptID]
	return st, ok
}

// len returns the current in-flight retention count. Test-facing
// only; the production code MUST NOT condition behavior on this.
func (s *authAttemptStore) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.entries)
}

// isSpec010CatalogBadField reports whether a parser-level badField
// string identifies a SPEC-010 v1.5 R-3.1.9 catalog validation
// failure (length / array / duplicate / containment / empty), per
// SPEC-002 v1.3.5 AC-K.15. These badField values are LOCKED test
// oracles that MUST reach the wire verbatim.
func isSpec010CatalogBadField(badField string) bool {
	return strings.HasPrefix(badField, "supported_models")
}

func supportedModelsEqualUnderNFCASCIIFold(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if normalizeSupportedModelEntry(a[i]) != normalizeSupportedModelEntry(b[i]) {
			return false
		}
	}
	return true
}

func normalizeSupportedModelEntry(s string) string {
	return strings.ToLower(norm.NFC.String(s))
}
