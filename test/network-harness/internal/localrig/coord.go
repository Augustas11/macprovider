package localrig

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type coordYAMLInputs struct {
	buyerPort           int
	provPort            int
	dbPath              string
	operatorKey         string
	gatewayServiceToken string
	providers           []Provider
	providerPorts       []int
}

// writeCoordinatorYAML mirrors the fields test/integration writes for a
// pinned-providers stack, adapted for the load rig:
//   - settlement is off (verified_model_settlement_mode="observe"),
//   - require_provider_tokens=true (we issue tokens per provider),
//   - admission.pinned_only=true (every rig provider is pinned),
//   - sticky_enabled=false (baseline scenario 17 is non-sticky).
func writeCoordinatorYAML(path string, in coordYAMLInputs) error {
	providersCfg := make([]map[string]any, len(in.providers))
	for i, p := range in.providers {
		providersCfg[i] = map[string]any{
			"provider_id":  p.ID,
			"endpoint_url": fmt.Sprintf("http://127.0.0.1:%d", in.providerPorts[i]),
			"display_name": fmt.Sprintf("fake-%s", p.ID),
		}
	}
	cfg := map[string]any{
		"listen": map[string]any{
			"buyer_port":    in.buyerPort,
			"provider_port": in.provPort,
			"bind_address":  "127.0.0.1",
		},
		"pool": map[string]any{
			"heartbeat_interval_s":       1,
			"disconnect_grace_period_s":  30,
			"heartbeat_miss_threshold_s": 90,
			"wake_gap_threshold_s":       120,
			"warmup_fallback_s":          60,
			"warmup_gate_enabled":        false,
			"degraded_backoff_s":         30,
			"degraded_max_retries":       3,
			"degraded_probe_after_502":   true,
			"breaker_failure_threshold":  2,
			"breaker_window_s":           120,
		},
		"routing": map[string]any{
			"preflight_threshold_tokens":        4096,
			"preflight_timeout_s":               5,
			"request_timeout_s":                 60,
			"failover_enabled":                  true,
			"failover_timeout_s":                5,
			"retry_per_attempt_timeout_s":       60,
			"max_providers_faulted_per_request": 0,
			"sticky_enabled":                    false,
			"sticky_ttl_s":                      1800,
			"sticky_max_entries":                10000,
		},
		"provider_http": map[string]any{
			"timeout_s": 30,
		},
		"limits": map[string]any{
			"max_chat_request_body_bytes": 1048576,
		},
		"ws": map[string]any{
			"write_buffer_size":               64,
			"handshake_timeout_s":             10,
			"write_timeout_s":                 10,
			"max_frame_bytes":                 4 << 20,
			"max_unauthenticated_conn":        64,
			"max_unauthenticated_conn_per_ip": 16,
		},
		"admission": map[string]any{
			"pinned_only":                         true,
			"provisional_admission_rate_per_hour": 1000,
			"provisional_pool_max":                100,
			"provisional_quota_per_hour":          1000,
			"provisional_tier_weight":             0.3,
			"provisional_retention_days":          30,
		},
		"tier2": map[string]any{
			"observe_enabled":                    false,
			"require_hash_verified":              false,
			"require_encrypted_leg":              false,
			"encrypted_leg_aead":                 "A256GCM",
			"encrypted_leg_rekey_after_requests": 10000,
			"encrypted_leg_rekey_after_seconds":  3600,
			"require_attestation":                false,
			"attestation_max_age_s":              600,
			"behavioral_safety_enabled":          false,
			"output_size_cap_bytes":              0,
			"output_bytes_per_token_ceiling":     16,
			"default_output_size_cap_bytes":      1048576,
			"encoding_validation_enabled":        false,
			"response_time_anomaly_enabled":      false,
			"response_time_anomaly_factor":       5.0,
			"response_time_anomaly_min_ms":       10000,
		},
		"auth": map[string]any{
			"operator_key":            in.operatorKey,
			"gateway_service_token":   in.gatewayServiceToken,
			"require_provider_tokens": true,
		},
		"storage": map[string]any{
			"db_path":                    in.dbPath,
			"snapshot_interval_s":        300,
			"request_log_retention_days": 90,
			"audit_log_retention_days":   90,
		},
		"logging": map[string]any{
			"level":  "info",
			"format": "json",
		},
		"rewards": map[string]any{
			"global_multiplier": 1.0,
			"provider_share":    0.9,
			"rate_card": map[string]any{
				"default": map[string]any{
					"prompt_credits_per_mtok":     500000,
					"completion_credits_per_mtok": 1000000,
				},
			},
		},
		"settlement": map[string]any{
			"cadence_days":                   7,
			"min_payout_credits":             0,
			"startup_reconcile_window_hours": 24,
			"nightly_reconcile_window_days":  7,
			"recovery_grace_seconds":         30,
			"verified_model_settlement_mode": "observe",
			"job_enabled":                    false,
		},
		"endpoints": map[string]any{
			"provider_earnings": map[string]any{
				"rate_limit_per_minute": 60,
			},
		},
		"explorer": map[string]any{
			"enabled": false,
		},
		"providers": providersCfg,
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	return os.WriteFile(path, b, 0o600)
}

// issueProviderToken shells out to coordinator-cli issue-token, which
// creates + migrates the DB (matching the integration harness pattern
// so the coordinator binary can attach to the same WAL DB on start).
// The CLI prints "token=<hex>" on stdout; we parse that line.
func issueProviderToken(coordCLIBin, dbPath, providerID, providerName string) (string, error) {
	cmd := exec.Command(coordCLIBin, "issue-token",
		"-db", dbPath,
		"-provider-id", providerID,
		"-provider-name", providerName,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("coordinator-cli issue-token: %v\n%s", err, string(out))
	}
	for _, line := range strings.Split(string(out), "\n") {
		if rest, ok := strings.CutPrefix(line, "token="); ok {
			return strings.TrimSpace(rest), nil
		}
	}
	return "", fmt.Errorf("issue-token: no token= line in output: %s", string(out))
}

func startCoordinator(ctx context.Context, r *Rig, bin, yamlPath string) error {
	cmd := exec.CommandContext(ctx, bin, "-config", yamlPath)
	cmd.Env = os.Environ()
	return r.registerProc(cmd, "coord")
}

// waitForHealth polls url until it returns 200 or the deadline expires.
func waitForHealth(ctx context.Context, url string) error {
	deadline := time.Now().Add(15 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
			lastErr = fmt.Errorf("status %d", resp.StatusCode)
		} else {
			lastErr = err
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("healthz %s never ready: %v", url, lastErr)
}

// waitForProvidersReady polls /poolz with the operator bearer until
// every providerID appears with state=ready. Deadline 30s — rig
// startup is slower than test/integration's 15s once N providers are
// heartbeating.
func waitForProvidersReady(ctx context.Context, provURL string, providerIDs []string, operatorKey string) error {
	deadline := time.Now().Add(30 * time.Second)
	var lastBody []byte
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, provURL+"/poolz", nil)
		req.Header.Set("Authorization", "Bearer "+operatorKey)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		lastBody = body
		if resp.StatusCode == http.StatusOK && allProvidersReady(body, providerIDs) {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("providers never all-ready in /poolz; last body: %s", string(lastBody))
}

// allProvidersReady returns true when every providerID has at least
// one entry with "state":"ready" in the /poolz body. /poolz emits an
// array of provider records; a substring scan is sufficient at rig
// scale (N < 100) and avoids depending on the coordinator's exact
// wire shape.
func allProvidersReady(body []byte, ids []string) bool {
	// Try to decode as an object with a slice of provider entries; on
	// failure fall back to substring match so a schema tweak doesn't
	// hard-break the rig.
	var wrapper struct {
		Providers []struct {
			ProviderID string `json:"provider_id"`
			State      string `json:"state"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(body, &wrapper); err == nil && len(wrapper.Providers) > 0 {
		ready := make(map[string]bool, len(wrapper.Providers))
		for _, p := range wrapper.Providers {
			if p.State == "ready" {
				ready[p.ProviderID] = true
			}
		}
		for _, id := range ids {
			if !ready[id] {
				return false
			}
		}
		return true
	}
	// Fallback: every ID must appear AND the body must contain
	// "state":"ready" at least once. Weak but matches how
	// test/integration's waitForProviderReady checks.
	if !strings.Contains(string(body), `"state":"ready"`) {
		return false
	}
	for _, id := range ids {
		if !strings.Contains(string(body), id) {
			return false
		}
	}
	return true
}
