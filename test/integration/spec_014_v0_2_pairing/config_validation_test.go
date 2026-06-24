package spec014pairing

import (
	"strings"
	"testing"
)

func TestSpec014V02CoordinatorConfigValidationMissingGitHubEnv(t *testing.T) {
	required := map[string]string{
		"GITHUB_OAUTH_CLIENT_ID":     "client-id",
		"GITHUB_OAUTH_CLIENT_SECRET": "client-secret",
		"GITHUB_OAUTH_REDIRECT_URI":  "https://coordinator.example/v1/auth/github/callback",
		"PORTAL_BASE_URL":            "https://portal.example",
	}
	for missing := range required {
		t.Run(missing, func(t *testing.T) {
			env := map[string]string{"GITHUB_OAUTH_ENABLED": "true"}
			for k, v := range required {
				if k != missing {
					env[k] = v
				}
			}
			out := runCoordinatorExpectFailure(t, env)
			if !strings.Contains(out, missing) {
				t.Fatalf("coordinator failure output %q does not name %s", out, missing)
			}
		})
	}
}
