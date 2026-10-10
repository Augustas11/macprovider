package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/rs/zerolog"
)

func TestConfigureLogging(t *testing.T) {
	previous := zerolog.GlobalLevel()
	t.Cleanup(func() { zerolog.SetGlobalLevel(previous) })
	for _, tc := range []struct {
		level string
		debug bool
	}{{"", false}, {"info", false}, {"debug", true}} {
		t.Run(tc.level, func(t *testing.T) {
			var out bytes.Buffer
			// Construct before applying config, like the early boot logger.
			logger := zerolog.New(&out)
			if err := configureLogging(config.LoggingConfig{Level: tc.level}); err != nil {
				t.Fatal(err)
			}
			logger.Debug().Msg("debug-event")
			logger.Info().Msg("info-event")
			logger.Warn().Msg("warn-event")
			logger.Error().Msg("error-event")
			if strings.Contains(out.String(), "debug-event") != tc.debug {
				t.Fatalf("debug visibility: %s", &out)
			}
			for _, event := range []string{"info-event", "warn-event", "error-event"} {
				if !strings.Contains(out.String(), event) {
					t.Fatalf("missing %s: %s", event, &out)
				}
			}
		})
	}
	before := zerolog.GlobalLevel()
	if err := configureLogging(config.LoggingConfig{Level: "bogus"}); err == nil {
		t.Fatal("invalid level accepted")
	}
	if zerolog.GlobalLevel() != before {
		t.Fatal("invalid level changed filter")
	}
}
