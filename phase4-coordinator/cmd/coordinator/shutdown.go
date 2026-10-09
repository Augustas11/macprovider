package main

import (
	"context"
	"errors"
	"net/http"

	"github.com/rs/zerolog"
)

// shutdownHTTPServer retains a failed drain's status while forcing remaining
// HTTP connections closed. Hijacked provider sessions are closed separately by
// the caller, which must continue teardown even when the shared deadline expires.
func shutdownHTTPServer(ctx context.Context, server *http.Server, name string, logger zerolog.Logger) error {
	if err := server.Shutdown(ctx); err != nil {
		logger.Error().Err(err).Str("server", name).Msg("http shutdown failed; forcing connections closed")
		closeErr := server.Close()
		if closeErr != nil {
			logger.Error().Err(closeErr).Str("server", name).Msg("http force close failed")
		}
		return errors.Join(err, closeErr)
	}
	return nil
}
