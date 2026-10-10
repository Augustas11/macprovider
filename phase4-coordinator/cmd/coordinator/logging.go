package main

import (
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/rs/zerolog"
)

// The global filter covers every logger in the daemon. Logging changes require
// a restart, like other startup-only settings; SIGHUP does not change the filter.
func configureLogging(cfg config.LoggingConfig) error {
	level, err := cfg.LogLevel()
	if err != nil {
		return err
	}
	zerolog.SetGlobalLevel(level)
	return nil
}
