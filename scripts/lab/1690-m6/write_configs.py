#!/usr/bin/env python3
"""Write the #1690 M6 lab coordinator, gateway, and provider configs.

Lab only: every listener binds 127.0.0.1 on the 191xx block, every path is
under LAB, and every secret is generated here (LAB/keys/secrets.json). YAML is
a JSON superset, so the configs are written as JSON. Noninteractive.
"""
import json
import os
import pathlib
import secrets
import sys

LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-1690-m6"))
PORTS = {"coord_buyer": 19101, "coord_provider": 19102, "gateway": 19110, "serve": 19120, "llama": 19130}
PROVIDER_ID = "lab-1690-m6-provider"
BUYER_ACCOUNT = "acct-lab-1690-buyer"
CREATOR_ACCOUNT = "acct-lab-1690-creator"
ROW_KEY = "qwen2.5-0.5b-instruct"
MLX_MODEL_ID = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
GGUF = LAB / "models" / "qwen2.5-0.5b-instruct-q4_k_m.gguf"

for port in PORTS.values():
    if port in (8080, 8443, 8444) or not 19100 <= port <= 19199:
        sys.exit(f"refusing non-lab port {port}")


def secret_bundle():
    path = LAB / "keys" / "secrets.json"
    if path.exists():
        return json.loads(path.read_text())
    bundle = {name: secrets.token_hex(32) for name in (
        "operator_key", "operator_lab_a", "operator_lab_b", "gateway_service_token", "key_hash_secret", "demo_secret")}
    path.write_text(json.dumps(bundle, indent=2))
    path.chmod(0o600)
    return bundle


def main():
    s = secret_bundle()
    static = LAB / "static"
    pub = (static / "static-public-key.base64").read_text().strip()
    tier2_pub = (LAB / "keys" / "tier2.pub").read_text().strip()
    rate_card = json.loads((static / "rate-card.json").read_text())
    rows = {k: {"prompt_credits_per_mtok": v["prompt_rate_per_mtok"],
                "prompt_cache_hit_credits_per_mtok": v["prompt_cache_hit_rate_per_mtok"],
                "completion_credits_per_mtok": v["completion_rate_per_mtok"]} for k, v in rate_card["rows"].items()}
    default = rate_card["rows"]["default"]
    coord = {
        "listen": {"buyer_port": PORTS["coord_buyer"], "provider_port": PORTS["coord_provider"], "bind_address": "127.0.0.1"},
        "coordinator": {"require_gateway_context": True},
        "pool": {"heartbeat_interval_s": 2, "disconnect_grace_period_s": 30, "heartbeat_miss_threshold_s": 90,
                 "wake_gap_threshold_s": 120, "warmup_fallback_s": 60, "warmup_gate_enabled": False,
                 "degraded_backoff_s": 30, "degraded_max_retries": 3, "breaker_failure_threshold": 2,
                 "breaker_window_s": 120, "canary_enabled": False},
        "routing": {"preflight_threshold_tokens": 4096, "preflight_timeout_s": 5, "request_timeout_s": 300,
                    "failover_enabled": False, "failover_timeout_s": 5, "retry_per_attempt_timeout_s": 300,
                    "max_providers_faulted_per_request": 0, "sticky_enabled": False},
        "provider_http": {"timeout_s": 300},
        "admission": {"pinned_only": False, "provisional_admission_rate_per_hour": 1000, "provisional_pool_max": 100,
                      "provisional_quota_per_hour": 100000, "provisional_tier_weight": 0.3, "provisional_retention_days": 30},
        "autotune": {
            "enforce_provider_admission": True,
            "public_keys": {"lab-1690-m6-static": pub},
            "rate_card_path": str(static / "rate-card.json"), "rate_card_sig_path": str(static / "rate-card.json.sig"),
            "demand_rank_path": str(static / "demand-rank.json"), "demand_rank_sig_path": str(static / "demand-rank.json.sig"),
            "autotune_candidates_path": str(static / "autotune-candidates.json"),
            "autotune_candidates_sig_path": str(static / "autotune-candidates.json.sig"),
            "catalog_artifacts_path": str(static / "catalog-artifacts.json"),
            "catalog_artifacts_sig_path": str(static / "catalog-artifacts.json.sig"),
        },
        "tier2": {"observe_enabled": True, "require_hash_verified": True, "catalog_path": str(static / "tier2-catalog.json"),
                  "catalog_public_key": tier2_pub},
        "auth": {"operator_key": s["operator_key"], "operator_keys": {"lab_a": s["operator_lab_a"], "lab_b": s["operator_lab_b"]},
                 "gateway_service_token": s["gateway_service_token"], "require_provider_tokens": True},
        "storage": {"db_path": str(LAB / "db" / "coordinator.db"), "snapshot_interval_s": 300,
                    "request_log_retention_days": 90, "audit_log_retention_days": 90},
        "trusted_pools": {"enabled": True, "refresh_interval_s": 1},
        "logging": {"level": "debug", "format": "json"},
        "rewards": {"global_multiplier": default["global_multiplier_ppm"] / 1e6, "provider_share": default["provider_share_bps"] / 1e4,
                    "rate_card": rows},
        "settlement": {"cadence_days": 7, "min_payout_credits": 0, "startup_reconcile_window_hours": 24,
                       "nightly_reconcile_window_days": 7, "recovery_grace_seconds": 30, "pending_deadline_seconds": 300,
                       "verified_model_settlement_mode": "enforce", "job_enabled": False},
        "relay_blind": {"enabled": False},
        "explorer": {"enabled": False},
    }
    gw_db = LAB / "db" / "gateway.db"
    gateway = {
        "listen": {"bind_address": "127.0.0.1", "port": PORTS["gateway"]},
        "proxy": {"trusted_cidrs": ["127.0.0.0/8", "::1/128"]},
        "public": {"base_url": f"http://127.0.0.1:{PORTS['gateway']}", "account_path": "/account"},
        "coordinator": {"buyer_url": f"http://127.0.0.1:{PORTS['coord_buyer']}", "operator_url": f"http://127.0.0.1:{PORTS['coord_provider']}",
                        "operator_key": s["operator_key"], "service_token": s["gateway_service_token"], "poolz_poll_interval_s": 60},
        "storage": {"driver": "sqlite", "db_path": str(gw_db)},
        "auth": {"key_prefix": "mp_", "key_hash": "hmac_sha256", "key_hash_secret": s["key_hash_secret"],
                 "github_oauth_enabled": False, "email_magic_link_enabled": False,
                 "oauth": {"state_max_per_ip": 20, "callback_allowlist": [f"http://127.0.0.1:{PORTS['gateway']}/auth/github/callback"]},
                 "demo": {"signing_secret": s["demo_secret"]}},
        "quotas": {"account_daily_tokens": 1000000, "demo_daily_tokens_per_ip": 10000, "demo_sessions_per_ip_per_hour": 10,
                   "account_concurrency": 8, "demo_concurrency": 4, "signup_accounts_per_ip_per_day": 3,
                   "reaper_interval_hours": 24, "reservation_max_age_hours": 24},
        "limits": {"max_tokens_per_request": 4096, "demo_max_tokens_per_request": 512, "max_feedback_comment_bytes": 2000,
                   "max_feedback_body_bytes": 16384, "feedback_requests_per_ip_per_hour": 10, "request_body_bytes": 1048576},
        "capacity": {"monthly_budget_usd": 500, "ready_provider_degraded_threshold": 1, "projected_cost_tier1_percent": 80,
                     "tier_cooldown_seconds": 3600},
        "timeouts": {"coordinator_request_seconds": 300, "coordinator_header_timeout_seconds": 300, "streaming_cancel_ms": 500},
        "cors": {"allowed_origins": [f"http://127.0.0.1:{PORTS['gateway']}"]},
        "routing": {"sticky_enabled": False, "sticky_ttl_s": 1800},
        "features": {"trusted_pools": {"enabled": True, "coordinator_authorizes": True}},
        "settlement": {"reconcile_enabled": True, "reconcile_interval_s": 5, "reconcile_batch_limit": 100, "reconcile_request_timeout_s": 5},
        "explorer": {"enabled": False},
    }
    (LAB / "run" / "coordinator.yaml").write_text(json.dumps(coord, indent=2))
    (LAB / "run" / "gateway.yaml").write_text(json.dumps(gateway, indent=2))
    for p in ("coordinator.yaml", "gateway.yaml"):
        (LAB / "run" / p).chmod(0o600)
    print(json.dumps({"ports": PORTS, "provider_id": PROVIDER_ID, "buyer_account": BUYER_ACCOUNT}))


if __name__ == "__main__":
    main()
