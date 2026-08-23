package buyer

import (
	"context"
	"net/http"
	"sync"
	"sync/atomic"
)

// withPoolProviderRevocationCancel wraps a provider attempt with the SPEC-042
// revoke_immediate active-cut signal. It is inert for global requests and for
// lifecycle-only pool changes; only the durable provider-specific revocation
// blocklist cancels an already-dispatched attempt.
func (s *Server) withPoolProviderRevocationCancel(parent context.Context, state *forwardState, providerID string) (context.Context, func(), func() bool) {
	if parent == nil {
		parent = context.Background()
	}
	if s == nil || s.trustPools == nil || state == nil || state.poolID == "" || providerID == "" {
		return parent, func() {}, func() bool { return false }
	}

	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})
	var stopOnce sync.Once
	var cancelled atomic.Bool
	revoked, unwatch, alreadyRevoked := s.trustPools.WatchProviderRevoked(state.poolID, providerID)

	stop := func() {
		stopOnce.Do(func() {
			close(done)
			unwatch()
			cancel()
		})
	}
	if alreadyRevoked {
		cancelled.Store(true)
		cancel()
		return ctx, stop, cancelled.Load
	}
	go func() {
		select {
		case <-parent.Done():
		case <-done:
		case <-revoked:
			cancelled.Store(true)
			cancel()
		}
	}()

	return ctx, stop, func() bool {
		return cancelled.Load() || s.trustPools.ProviderRevoked(state.poolID, providerID)
	}
}

func (s *Server) poolAttemptCancelledDuringDispatch(r *http.Request, state *forwardState) (dispatchedAttempt, bool) {
	if r == nil {
		return dispatchedAttempt{}, false
	}
	revoked := false
	if s != nil && s.trustPools != nil && state != nil && state.poolID != "" && state.provider.ProviderID != "" {
		revoked = s.trustPools.ProviderRevoked(state.poolID, state.provider.ProviderID)
	}
	if r.Context().Err() == nil && !revoked {
		return dispatchedAttempt{}, false
	}
	err := r.Context().Err()
	if err == nil {
		err = context.Canceled
	}
	return dispatchedAttempt{tr: transportResult{
		status:    http.StatusBadGateway,
		err:       err,
		attempt:   requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider disconnected; buyer should retry"},
		retryable: true,
	}}, true
}

func (s *Server) poolAttemptCancelledBeforeCommit(r *http.Request, state *forwardState, providerID string) bool {
	if r != nil && r.Context().Err() != nil {
		return true
	}
	if s == nil || s.trustPools == nil || state == nil || state.poolID == "" || providerID == "" {
		return false
	}
	return s.trustPools.ProviderRevoked(state.poolID, providerID)
}
