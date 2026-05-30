package config

import (
	"strings"
	"testing"
)

func TestModelClassRejectsMembersAndModelsTogether(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Routing.ModelClasses = map[string]ModelClassConfig{
		"alias": {Members: []string{"model-a"}, Models: []string{"model-b"}, Objective: "fast"},
	}

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "must not set both members and models") {
		t.Fatalf("Validate error=%v", err)
	}
}
