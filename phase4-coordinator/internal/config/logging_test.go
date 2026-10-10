package config

import (
	"strings"
	"testing"

	"github.com/rs/zerolog"
)

func TestLoggingLevelValidation(t *testing.T) {
	for _, value := range []string{"", "debug", "info", "INFO", "warn"} {
		t.Run(value, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.Logging.Level = value
			if err := cfg.Validate(); err != nil {
				t.Fatal(err)
			}
		})
	}
	for _, value := range []string{"verbose", "none", "-1", "0", " info ", "trace", "error", "fatal", "panic", "disabled"} {
		cfg := validTestConfig()
		cfg.Logging.Level = value
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "logging.level") {
			t.Fatalf("level %q: got %v, want logging.level rejection", value, err)
		}
	}
	for _, cfg := range []LoggingConfig{{}, Default().Logging} {
		if level, err := cfg.LogLevel(); err != nil || level != zerolog.InfoLevel {
			t.Fatalf("default level = %v, %v; want info", level, err)
		}
	}
}
