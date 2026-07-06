package localrig

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"gopkg.in/yaml.v3"

	_ "modernc.org/sqlite"
)

type gwYAMLInputs struct {
	gwPort        int
	dbPath        string
	coordBuyerURL string
	coordProvURL  string
	operatorKey   string
	serviceToken  string
	keyHashSecret string
	demoSecret    string
}

// writeGatewayYAML mirrors the fields test/integration writes. Sticky
// is OFF (baseline scenario 17); PR 2 will lift the knob into Config.
func writeGatewayYAML(path string, in gwYAMLInputs) error {
	cfg := map[string]any{
		"listen": map[string]any{
			"bind_address": "127.0.0.1",
			"port":         in.gwPort,
		},
		"proxy": map[string]any{
			"trusted_cidrs": []string{"127.0.0.0/8", "::1/128"},
		},
		"public": map[string]any{
			"base_url":     fmt.Sprintf("http://127.0.0.1:%d", in.gwPort),
			"account_path": "/account",
		},
		"coordinator": map[string]any{
			"buyer_url":             in.coordBuyerURL,
			"operator_url":          in.coordProvURL,
			"operator_key":          in.operatorKey,
			"service_token":         in.serviceToken,
			"poolz_poll_interval_s": 60,
		},
		"storage": map[string]any{
			"driver":  "sqlite",
			"db_path": in.dbPath,
		},
		"auth": map[string]any{
			"key_prefix":               "mp_",
			"key_hash":                 "hmac_sha256",
			"key_hash_secret":          in.keyHashSecret,
			"github_oauth_enabled":     false,
			"email_magic_link_enabled": false,
			"oauth": map[string]any{
				"state_max_per_ip": 20,
				"callback_allowlist": []string{
					fmt.Sprintf("http://127.0.0.1:%d/auth/github/callback", in.gwPort),
				},
			},
			"demo": map[string]any{
				"signing_secret": in.demoSecret,
			},
		},
		"quotas": map[string]any{
			"account_daily_tokens":           1000000,
			"demo_daily_tokens_per_ip":       10000,
			"demo_sessions_per_ip_per_hour":  10,
			"account_concurrency":            256,
			"demo_concurrency":               4,
			"signup_accounts_per_ip_per_day": 3,
			"reaper_interval_hours":          24,
			"reservation_max_age_hours":      24,
		},
		"limits": map[string]any{
			"max_tokens_per_request":            4096,
			"demo_max_tokens_per_request":       512,
			"max_feedback_comment_bytes":        2000,
			"max_feedback_body_bytes":           16384,
			"feedback_requests_per_ip_per_hour": 10,
			"request_body_bytes":                1048576,
		},
		"capacity": map[string]any{
			"monthly_budget_usd":                500,
			"ready_provider_degraded_threshold": 1,
			"projected_cost_tier1_percent":      80,
			"tier_cooldown_seconds":             3600,
		},
		"timeouts": map[string]any{
			"coordinator_request_seconds":        60,
			"coordinator_header_timeout_seconds": 60,
			"streaming_cancel_ms":                500,
		},
		"cors": map[string]any{
			"allowed_origins": []string{fmt.Sprintf("http://127.0.0.1:%d", in.gwPort)},
		},
		"routing": map[string]any{
			"sticky_enabled": false,
			"sticky_ttl_s":   1800,
		},
		"explorer": map[string]any{
			"enabled": false,
		},
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	return os.WriteFile(path, b, 0o600)
}

// seedGatewayAccountAndKey boots the gateway briefly so it runs its
// schema migrations, kills it, then writes an active accounts row and
// one api_keys row directly. The key hash uses
// HMAC-SHA256(key_hash_secret, fullKey) — same shape as
// phase5-gateway/internal/auth/keys.go. Returns the full mp_… key.
//
// Never log the returned key — it's a live bearer for the rig's
// lifetime.
func seedGatewayAccountAndKey(ctx context.Context, gwBin, gwYAML, gwDB, keyHashSecret, accountID string) (string, error) {
	bootCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(bootCtx, gwBin, "-config", gwYAML)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("boot gateway for seed: %w", err)
	}
	// Poll until the schema is present, then kill.
	seeded := false
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		db, err := sql.Open("sqlite", gwDB)
		if err == nil {
			var ok int
			err = db.QueryRow(`SELECT 1 FROM sqlite_master WHERE type='table' AND name='accounts'`).Scan(&ok)
			db.Close()
			if err == nil {
				seeded = true
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	if !seeded {
		return "", fmt.Errorf("gateway schema not present after 6s")
	}

	db, err := sql.Open("sqlite", gwDB)
	if err != nil {
		return "", fmt.Errorf("open gateway db: %w", err)
	}
	defer db.Close()
	now := time.Now().UTC().Format(time.RFC3339Nano)

	if _, err := db.Exec(
		`INSERT INTO accounts(account_id, status, quota_class, concurrency_class, created_at) VALUES(?, 'active', 'default', 'default', ?)`,
		accountID, now,
	); err != nil {
		return "", fmt.Errorf("seed account: %w", err)
	}

	rawKey := make([]byte, 32)
	if _, err := rand.Read(rawKey); err != nil {
		return "", fmt.Errorf("rand: %w", err)
	}
	fullKey := "mp_" + base64.RawURLEncoding.EncodeToString(rawKey)
	mac := hmac.New(sha256.New, []byte(keyHashSecret))
	_, _ = mac.Write([]byte(fullKey))
	hash := mac.Sum(nil)
	prefix := fullKey
	if len(fullKey) > 12 {
		prefix = fullKey[:12]
	}
	keyIDSuffix, err := randHex(16)
	if err != nil {
		return "", fmt.Errorf("gen key id: %w", err)
	}
	keyID := "key_" + keyIDSuffix
	if _, err := db.Exec(
		`INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at) VALUES(?, ?, ?, ?, 'active', ?)`,
		keyID, accountID, hash, prefix, now,
	); err != nil {
		return "", fmt.Errorf("seed api_key: %w", err)
	}
	return fullKey, nil
}

func startGateway(ctx context.Context, r *Rig, bin, yamlPath string) error {
	cmd := exec.CommandContext(ctx, bin, "-config", yamlPath)
	cmd.Env = os.Environ()
	return r.registerProc(cmd, "gateway")
}
