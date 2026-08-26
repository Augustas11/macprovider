#!/usr/bin/env python3
"""Build the #1188 Malibu operator fleet ledger."""

from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


USER_BUCKETS = (
    "Healthy",
    "Repair provider software",
    "Offline/connectivity",
    "Trust verification needed",
    "Cooldown/requalification",
)

HOME_ACL_RE = re.compile(r"acl_write_rejected:(?P<path>[^\r\n]+)", re.IGNORECASE)
NO_ESTABLISHED_TCP = "no ESTABLISHED TCP"
COORDINATOR_TIER_RE = re.compile(r"Coordinator tier:\s*(?P<tier>[A-Za-z0-9_-]+)")
NEWER_VERSION_RE = re.compile(r"A newer version is available \(v(?P<version>[0-9]+(?:\.[0-9]+){1,2})\)")
PROVIDER_ID_RE = re.compile(r"provider_id[:=]\s*(?P<id>\S+)")
REPAIR_FAILED_RE = re.compile(
    r"("
    r"Provider software could not be verified for repair|"
    r"repairEvidenceMissing|"
    r"repair evidence|"
    r"repair already failed|"
    r"Repair provider software failed|"
    r"Provider software install failed|"
    r"exit\s+(20|28)"
    r")",
    re.IGNORECASE,
)
REPAIR_SIGNATURE_RE = re.compile(
    r"("
    r"acl_write_rejected:|"
    r"provider software repair|"
    r"repair provider software|"
    r"catalog_update_required|"
    r"catalog_incompatible|"
    r"required_binary_version|"
    r"binary_version_mismatch|"
    r"version_unsupported|"
    r"below required"
    r")",
    re.IGNORECASE,
)
TRUST_SIGNATURE_RE = re.compile(
    r"("
    r"self_minted|"
    r"bearerless_duplicate|"
    r"mint_failed|"
    r"invalid_token|"
    r"token_untrusted|"
    r"trust_tier_provisional|"
    r"held_provisional_trust_tier|"
    r"hardware_evidence_missing|"
    r"hardware_evidence_missing_or_expired|"
    r"hardware_evidence_unavailable|"
    r"autotune_evidence_required|"
    r"app_attestation_missing|"
    r"attestation_failed|"
    r"attestation_stale|"
    r"hash_mismatch|"
    r"hash_invalid|"
    r"insufficient_verified_receipts"
    r")",
    re.IGNORECASE,
)

ADMISSION_POLICY_FLAG_KEYS = (
    "admission_ceiling_excluded",
    "admission_evidence_stale",
    "admission_sandboxed",
    "benchmark_quarantined",
    "policy_ineligible",
    "route_excluded",
)
LIVE_POOLZ_TRUTH_KEYS = {
    "assigned_id",
    "admission_ceiling_excluded",
    "admission_evidence_stale",
    "admission_sandboxed",
    "auth_state",
    "attestation_status",
    "benchmark_quarantined",
    "binary_version",
    "catalog_admission_mode",
    "cli_version",
    "connected_at",
    "coordinator_presence",
    "encrypted_leg",
    "hash_status",
    "host",
    "hostname",
    "last_activity_at",
    "last_autoupdate_event",
    "last_heartbeat_at",
    "last_seen_at",
    "machine_name",
    "model",
    "model_id",
    "presence",
    "routing_eligibility",
    "routing_eligible",
    "safety_telemetry",
    "state",
    "tier",
    "require_attestation",
    "require_encrypted_leg",
    "require_hash_verified",
    "tier2_policy_eligible",
    "tier2_policy_reason",
    "trust_tier",
}
COOLDOWN_SIGNATURE_RE = re.compile(
    r"("
    r"demotion_cooldown|"
    r"held_demotion_cooldown|"
    r"cooldown|"
    r"requal|"
    r"quarantine|"
    r"benchmark_quarantined|"
    r"canary|"
    r"degraded|"
    r"admission_ceiling_excluded|"
    r"admission_evidence_stale|"
    r"admission_sandboxed"
    r")",
    re.IGNORECASE,
)
CSV_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r", "\n", "\uff1d", "\uff0b", "\uff0d", "\uff20")


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req: Request, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


@dataclass(frozen=True)
class FleetLedgerRow:
    source: str
    provider_id: str
    hostname: str
    malibu_app_version: str
    cli_version: str
    watchdog_repair_state: str
    model: str
    coordinator_presence: str
    routing_eligibility: str
    trust_tier: str
    hash_status: str
    attestation_status: str
    encrypted_leg: str
    catalog_admission_mode: str
    admission_policy_flags: str
    require_hash_verified: str
    require_attestation: str
    require_encrypted_leg: str
    tier2_policy_eligible: str
    tier2_policy_reason: str
    reward_hold_reason: str
    last_heartbeat: str
    last_error: str
    bucket: str
    bucket_reason: str
    operator_next_action: str
    evidence: list[str]

    def as_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "provider_id": self.provider_id,
            "hostname": self.hostname,
            "malibu_app_version": self.malibu_app_version,
            "cli_version": self.cli_version,
            "watchdog_repair_state": self.watchdog_repair_state,
            "model": self.model,
            "coordinator_presence": self.coordinator_presence,
            "routing_eligibility": self.routing_eligibility,
            "trust_tier": self.trust_tier,
            "hash_status": self.hash_status,
            "attestation_status": self.attestation_status,
            "encrypted_leg": self.encrypted_leg,
            "catalog_admission_mode": self.catalog_admission_mode,
            "admission_policy_flags": self.admission_policy_flags,
            "require_hash_verified": self.require_hash_verified,
            "require_attestation": self.require_attestation,
            "require_encrypted_leg": self.require_encrypted_leg,
            "tier2_policy_eligible": self.tier2_policy_eligible,
            "tier2_policy_reason": self.tier2_policy_reason,
            "reward_hold_reason": self.reward_hold_reason,
            "last_heartbeat": self.last_heartbeat,
            "last_error": self.last_error,
            "bucket": self.bucket,
            "bucket_reason": self.bucket_reason,
            "operator_next_action": self.operator_next_action,
            "evidence": self.evidence,
        }


def _string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value).strip()


def _has_value(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return value.strip() != ""
    if isinstance(value, (list, tuple, dict, set)):
        return len(value) > 0
    return True


def _first_value(payload: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = payload.get(key)
        if _has_value(value):
            return value
    return ""


def _join_values(value: Any) -> str:
    if isinstance(value, list):
        return ";".join(_string(item) for item in value if _string(item))
    return _string(value)


def _truthy(value: Any) -> bool:
    return _string(value).lower() in ("1", "true", "yes", "required", "require", "enabled")


def _logs(payload: dict[str, Any], name: str) -> list[str]:
    raw = payload.get("logs", {}).get(name, [])
    if not isinstance(raw, list):
        return []
    return [str(line) for line in raw]


def _all_log_lines(payload: dict[str, Any]) -> list[str]:
    raw_logs = payload.get("logs", {})
    if not isinstance(raw_logs, dict):
        return []
    lines: list[str] = []
    for raw in raw_logs.values():
        if isinstance(raw, list):
            lines.extend(str(line) for line in raw)
    return lines


def _first_match(pattern: re.Pattern[str], lines: Iterable[str], group: str) -> str:
    for line in lines:
        match = pattern.search(line)
        if match:
            return match.group(group).strip()
    return ""


def _count_matches(pattern: re.Pattern[str], lines: Iterable[str]) -> int:
    return sum(1 for line in lines if pattern.search(line))


def _count_home_acl(lines: Iterable[str]) -> tuple[int, str]:
    count = 0
    first_path = ""
    for line in lines:
        match = HOME_ACL_RE.search(line)
        if not match:
            continue
        count += 1
        if not first_path:
            first_path = match.group("path").strip()
    return count, first_path


def _jsonish_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    return _string(value)


def _text_blob(*values: Any) -> str:
    parts = [_jsonish_text(value) for value in values]
    return "\n".join(part for part in parts if part)


def _parse_timestamp(value: Any) -> datetime | None:
    raw = _string(value)
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _latest_timestamp(*values: Any) -> datetime | None:
    parsed = [item for item in (_parse_timestamp(value) for value in values) if item is not None]
    if not parsed:
        return None
    return max(parsed)


def _is_loopback_host(hostname: str | None) -> bool:
    if not hostname:
        return False
    if hostname.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def _validate_admin_request_url(url: str, *, allow_query: bool) -> str:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise SystemExit("admin URL must be absolute http(s)")
    if parsed.username or parsed.password:
        raise SystemExit("admin URL must not include username or password")
    if parsed.fragment or (parsed.query and not allow_query):
        raise SystemExit("admin base URL must not include query strings or fragments")
    if parsed.scheme == "http" and not _is_loopback_host(parsed.hostname):
        raise SystemExit("admin URL must use HTTPS except explicit loopback development")
    return url


def validate_admin_base_url(admin_url: str) -> str:
    return _validate_admin_request_url(admin_url.rstrip("/"), allow_query=False)


def _safe_request_label(url: str) -> str:
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        return "admin request"
    return f"{parsed.scheme}://{parsed.netloc}{parsed.path or '/'}"


def _validate_secret_file_stat(file_stat: os.stat_result, label: str) -> None:
    if not stat.S_ISREG(file_stat.st_mode):
        raise SystemExit(f"{label} must be a regular file")
    if hasattr(os, "geteuid") and file_stat.st_uid != os.geteuid():
        raise SystemExit(f"{label} must be owned by the current user")
    if file_stat.st_mode & 0o077:
        raise SystemExit(f"{label} must not be group/world-readable; use chmod 600")


def _read_secret_file(path: Path, label: str) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise SystemExit(f"{label} is not readable") from exc
    with os.fdopen(fd, "r", encoding="utf-8") as handle:
        _validate_secret_file_stat(os.fstat(handle.fileno()), label)
        return handle.read().strip()


def validate_operator_token(token: str) -> str:
    if not token or any(ord(char) < 0x21 or ord(char) > 0x7E for char in token):
        raise SystemExit("operator bearer token is empty or malformed")
    return token


def _csv_safe(value: Any) -> str:
    if value is None:
        text = ""
    elif isinstance(value, bool):
        text = "true" if value else "false"
    else:
        text = str(value)
    if text.startswith(CSV_FORMULA_PREFIXES):
        return "'" + text
    return text


def _diagnostic_active_for_classification(
    *,
    diagnostics_only: bool,
    diagnostic_at: str,
    last_heartbeat: str,
    last_activity: str,
    connected_at: str,
) -> bool:
    if diagnostics_only:
        return True
    live_time = _latest_timestamp(last_heartbeat, last_activity, connected_at)
    if live_time is None:
        return True
    diagnostic_time = _parse_timestamp(diagnostic_at)
    return diagnostic_time is not None and diagnostic_time > live_time


def _routing_eligibility(value: Any) -> str:
    if isinstance(value, bool):
        return "eligible" if value else "ineligible"
    raw = _string(value).lower()
    if raw in ("true", "eligible", "routing_eligible", "ready", "buyer_serving"):
        return "eligible"
    if raw in ("false", "ineligible", "unavailable", "not_buyer_serving", "offline"):
        return "ineligible"
    return _string(value)


def _presence_from_value(value: Any) -> str:
    if isinstance(value, bool):
        return "connected" if value else "offline"
    raw = _string(value)
    lower = raw.lower()
    if lower in ("true", "connected", "online", "live", "ready", "buyer_serving"):
        return "connected"
    if lower in ("false", "offline", "disconnected", "network_offline", "unavailable"):
        return "offline"
    return raw


def _reward_hold_reason(provider: dict[str, Any]) -> str:
    direct = _join_values(_first_value(
        provider,
        "reward_hold_reason",
        "hold_or_mismatch_reason",
        "withdrawal_hold_reason",
    ))
    if direct:
        return direct
    reasons = _join_values(_first_value(provider, "withdrawal_hold_reasons", "hold_reasons"))
    if reasons:
        return reasons
    eligibility = provider.get("reward_eligibility")
    if isinstance(eligibility, dict):
        primary = _string(eligibility.get("primary_reason"))
        if primary:
            return primary
        return _join_values(eligibility.get("reasons"))
    return ""


def _admission_policy_flags(provider: dict[str, Any]) -> str:
    flags: list[str] = []
    for key in ADMISSION_POLICY_FLAG_KEYS:
        if key in provider and _has_value(provider[key]):
            flags.append(f"{key}={_string(provider[key])}")
    return ";".join(flags)


def _policy_integrity_alert(provider: dict[str, Any]) -> str:
    tier2_policy_eligible = _string(provider.get("tier2_policy_eligible")).lower()
    tier2_policy_reason = _string(provider.get("tier2_policy_reason"))
    if tier2_policy_eligible in ("false", "0", "no", "ineligible", "blocked", "denied") and tier2_policy_reason:
        return f"tier2 policy ineligible: {tier2_policy_reason}"

    hash_status = _string(_first_value(provider, "hash_status", "spec008_hash_status")).lower()
    if hash_status in ("hash_mismatch", "hash_invalid"):
        return f"model hash integrity status is {hash_status}"

    attestation_status = _string(provider.get("attestation_status")).lower()
    if attestation_status in ("failed", "attestation_failed", "stale", "attestation_stale"):
        return f"attestation status is {attestation_status}"
    return ""


def _trust_tier(provider: dict[str, Any], log_lines: Iterable[str] = ()) -> str:
    tier = _string(_first_value(
        provider,
        "trust_tier",
        "tier",
        "coordinator_tier",
        "rewards_trust_tier",
    ))
    if tier:
        return tier
    return _first_match(COORDINATOR_TIER_RE, log_lines, "tier")


def _last_error(provider: dict[str, Any], fallback_text: str = "") -> str:
    error = _string(_first_value(
        provider,
        "last_error",
        "diagnostic",
        "failure_reason",
        "close_reason",
        "error",
    ))
    if error:
        return error
    return fallback_text


def _watchdog_repair_state(text: str) -> str:
    has_home_acl = bool(HOME_ACL_RE.search(text))
    repair_failed = bool(REPAIR_FAILED_RE.search(text))
    repair_signal = bool(REPAIR_SIGNATURE_RE.search(text))
    lower = text.lower()
    if has_home_acl and repair_failed:
        return "watchdog_layer_repair_blocked"
    if repair_failed:
        return "repair_failed"
    if has_home_acl:
        return "home_acl_autoupdate_blocked"
    if "repairing provider software" in lower or "repair_in_progress" in lower:
        return "repair_in_progress"
    if repair_signal:
        return "repair_needed"
    return ""


def _bucket_for(
    *,
    watchdog_repair_state: str,
    coordinator_presence: str,
    routing_eligibility: str,
    trust_tier: str,
    hash_status: str,
    attestation_status: str,
    encrypted_leg: str,
    catalog_admission_mode: str,
    admission_policy_flags: str,
    policy_integrity_alert: str,
    reward_hold_reason: str,
    state: str,
    auth_state: str,
    last_error: str,
    connectivity_diagnostic_current: bool,
    diagnostics_only: bool,
) -> tuple[str, str, str]:
    combined = _text_blob(
        watchdog_repair_state,
        coordinator_presence,
        routing_eligibility,
        trust_tier,
        hash_status,
        attestation_status,
        encrypted_leg,
        catalog_admission_mode,
        admission_policy_flags,
        policy_integrity_alert,
        reward_hold_reason,
        state,
        auth_state,
        last_error,
    )
    combined_lower = combined.lower()

    if watchdog_repair_state or REPAIR_SIGNATURE_RE.search(combined):
        if watchdog_repair_state == "watchdog_layer_repair_blocked":
            return (
                "Repair provider software",
                "watchdog-layer repair blockage after repair/install failure",
                "Do not repeat Malibu app install or generic Repair. Preserve identity and collect watchdog launchd/log evidence for controlled recovery.",
            )
        return (
            "Repair provider software",
            "provider software, updater, or watchdog repair signal",
            "Use identity-preserving provider software repair only when there is no evidence that Repair already failed.",
        )

    if catalog_admission_mode.lower() == "update_bridge":
        return (
            "Repair provider software",
            "catalog admission mode is update_bridge for provider software recovery",
            "Use the provider software update/repair lane; update-bridge sessions are visible to operators but not buyer-routable.",
        )

    presence_lower = coordinator_presence.lower()
    state_lower = state.lower()
    if presence_lower in ("offline", "disconnected", "network_offline") or state_lower == "unavailable":
        return (
            "Offline/connectivity",
            "coordinator presence is offline or unavailable",
            "Check provider uptime, network reachability, and recent coordinator events before changing identity.",
        )
    connectivity_diagnostic = NO_ESTABLISHED_TCP.lower() in combined_lower or "network_offline" in combined_lower
    live_connected_eligible = coordinator_presence == "connected" and routing_eligibility == "eligible"
    if connectivity_diagnostic and (diagnostics_only or connectivity_diagnostic_current or not live_connected_eligible):
        return (
            "Offline/connectivity",
            "connection diagnostic indicates missing coordinator connectivity",
            "Debug coordinator reachability and WebSocket activity before local repair or trust changes.",
        )

    if COOLDOWN_SIGNATURE_RE.search(_text_blob(reward_hold_reason, state, last_error)):
        return (
            "Cooldown/requalification",
            "cooldown, quarantine, degradation, or requalification signal",
            "Wait for the cooldown/requalification owner or inspect the coordinator evidence that placed the hold.",
        )

    trust_lower = trust_tier.lower()
    if (
        trust_lower in ("provisional", "rejected")
        or policy_integrity_alert
        or TRUST_SIGNATURE_RE.search(_text_blob(auth_state, reward_hold_reason, last_error, combined))
    ):
        return (
            "Trust verification needed",
            "trust, auth, attestation, or reward-trust proof is incomplete",
            "Inspect coordinator trust and auth events before asking the provider to reinstall or rotate identity.",
        )

    if coordinator_presence == "connected" and routing_eligibility == "eligible":
        return (
            "Healthy",
            "coordinator reports connected and routing eligible",
            "Monitor; do not disturb the provider.",
        )

    if coordinator_presence == "connected" and routing_eligibility == "ineligible":
        return (
            "Cooldown/requalification",
            "provider is connected but not currently routing eligible",
            "Inspect coordinator routing exclusion facts and requalification state.",
        )

    return (
        "Offline/connectivity",
        "coordinator presence is missing from the source snapshot",
        "Pull coordinator admin detail/events first; ask for diagnostics only if admin state cannot explain the row.",
    )


def classify_provider_facts(provider: dict[str, Any], source: str) -> FleetLedgerRow:
    evidence: list[str] = []
    provider_id = _string(_first_value(provider, "provider_id", "id"))
    hostname = _string(_first_value(provider, "hostname", "host", "machine_name"))
    malibu_app_version = _string(_first_value(
        provider,
        "malibu_app_version",
        "app_version",
        "malibu_version",
    ))
    cli_version = _string(_first_value(provider, "cli_version", "binary_version", "provider_cli_version"))
    model = _string(_first_value(provider, "model", "model_id", "current_model_id"))
    coordinator_presence = _presence_from_value(_first_value(
        provider,
        "coordinator_presence",
        "presence",
        "coordinator_connected",
    ))
    routing_eligibility = _routing_eligibility(_first_value(provider, "routing_eligibility", "routing_eligible"))
    trust_tier = _trust_tier(provider)
    hash_status = _string(_first_value(provider, "hash_status", "spec008_hash_status"))
    attestation_status = _string(provider.get("attestation_status"))
    encrypted_leg = _string(provider.get("encrypted_leg"))
    catalog_admission_mode = _string(provider.get("catalog_admission_mode"))
    admission_policy_flags = _admission_policy_flags(provider)
    require_hash_verified = _string(provider.get("require_hash_verified"))
    require_attestation = _string(provider.get("require_attestation"))
    require_encrypted_leg = _string(provider.get("require_encrypted_leg"))
    tier2_policy_eligible = _string(provider.get("tier2_policy_eligible"))
    tier2_policy_reason = _string(provider.get("tier2_policy_reason"))
    policy_integrity_alert = _policy_integrity_alert(provider)
    reward_hold_reason = _reward_hold_reason(provider)
    live_last_heartbeat = _string(_first_value(provider, "last_heartbeat", "last_heartbeat_at"))
    last_heartbeat = live_last_heartbeat or _string(provider.get("last_seen_at"))
    last_activity = _string(_first_value(provider, "last_activity", "last_activity_at"))
    connected_at = _string(provider.get("connected_at"))
    diagnostic_at = _string(provider.get("diagnostic_at"))
    state = _string(_first_value(provider, "state", "ui_state", "network_state", "status"))
    auth_state = _string(provider.get("auth_state"))
    diagnostic = _last_error(provider)
    diagnostics_only = bool(provider.get("_diagnostics_only"))
    autoupdate = _first_value(provider, "last_autoupdate_event", "autoupdate_event")
    safety = provider.get("safety_telemetry") if isinstance(provider.get("safety_telemetry"), dict) else {}
    if not cli_version and isinstance(safety, dict):
        cli_version = _string(safety.get("binary_version"))
    if not model and isinstance(safety, dict):
        model = _string(safety.get("model_id"))
    if not coordinator_presence and isinstance(safety, dict):
        coordinator_presence = _presence_from_value(safety.get("coordinator_connected"))
    if not last_heartbeat and isinstance(safety, dict):
        last_heartbeat = _string(safety.get("observed_at"))
    if not live_last_heartbeat and isinstance(safety, dict):
        live_last_heartbeat = _string(safety.get("observed_at"))

    diagnostic_active = _diagnostic_active_for_classification(
        diagnostics_only=diagnostics_only,
        diagnostic_at=diagnostic_at,
        last_heartbeat=live_last_heartbeat,
        last_activity=last_activity,
        connected_at=connected_at,
    )
    classifier_provider = dict(provider)
    classifier_diagnostic = diagnostic
    if not diagnostic_active:
        classifier_diagnostic = ""
        for key in ("diagnostic", "last_error", "failure_reason", "close_reason", "error"):
            classifier_provider.pop(key, None)

    text = _text_blob(classifier_provider, classifier_diagnostic, autoupdate, reward_hold_reason, auth_state, state)
    watchdog_repair_state = _string(provider.get("watchdog_repair_state")) or _watchdog_repair_state(text)
    last_error = diagnostic
    classifier_last_error = last_error if diagnostic_active else ""
    connectivity_diagnostic_current = diagnostic_active

    for label, value in (
        ("coordinator_presence", coordinator_presence),
        ("routing_eligibility", routing_eligibility),
        ("state", state),
        ("auth_state", auth_state),
        ("trust_tier", trust_tier),
        ("hash_status", hash_status),
        ("attestation_status", attestation_status),
        ("encrypted_leg", encrypted_leg),
        ("catalog_admission_mode", catalog_admission_mode),
        ("admission_policy_flags", admission_policy_flags),
        ("require_hash_verified", require_hash_verified),
        ("require_attestation", require_attestation),
        ("require_encrypted_leg", require_encrypted_leg),
        ("tier2_policy_eligible", tier2_policy_eligible),
        ("tier2_policy_reason", tier2_policy_reason),
        ("reward_hold_reason", reward_hold_reason),
        ("watchdog_repair_state", watchdog_repair_state),
        ("last_heartbeat", last_heartbeat),
        ("diagnostic_at", diagnostic_at),
    ):
        if value:
            evidence.append(f"{label}={value}")
    if policy_integrity_alert:
        evidence.append(f"policy_integrity_alert={policy_integrity_alert}")
    if autoupdate:
        evidence.append("last_autoupdate_event_present=true")
    if last_error:
        evidence.append(f"last_error={last_error}")

    bucket, reason, action = _bucket_for(
        watchdog_repair_state=watchdog_repair_state,
        coordinator_presence=coordinator_presence,
        routing_eligibility=routing_eligibility,
        trust_tier=trust_tier,
        hash_status=hash_status,
        attestation_status=attestation_status,
        encrypted_leg=encrypted_leg,
        catalog_admission_mode=catalog_admission_mode,
        admission_policy_flags=admission_policy_flags,
        policy_integrity_alert=policy_integrity_alert,
        reward_hold_reason=reward_hold_reason,
        state=state,
        auth_state=auth_state,
        last_error=classifier_last_error,
        connectivity_diagnostic_current=connectivity_diagnostic_current,
        diagnostics_only=diagnostics_only,
    )

    if bucket not in USER_BUCKETS:
        raise AssertionError(f"invalid bucket {bucket!r}")

    return FleetLedgerRow(
        source=source,
        provider_id=provider_id,
        hostname=hostname,
        malibu_app_version=malibu_app_version,
        cli_version=cli_version,
        watchdog_repair_state=watchdog_repair_state,
        model=model,
        coordinator_presence=coordinator_presence,
        routing_eligibility=routing_eligibility,
        trust_tier=trust_tier,
        hash_status=hash_status,
        attestation_status=attestation_status,
        encrypted_leg=encrypted_leg,
        catalog_admission_mode=catalog_admission_mode,
        admission_policy_flags=admission_policy_flags,
        require_hash_verified=require_hash_verified,
        require_attestation=require_attestation,
        require_encrypted_leg=require_encrypted_leg,
        tier2_policy_eligible=tier2_policy_eligible,
        tier2_policy_reason=tier2_policy_reason,
        reward_hold_reason=reward_hold_reason,
        last_heartbeat=last_heartbeat,
        last_error=last_error,
        bucket=bucket,
        bucket_reason=reason,
        operator_next_action=action,
        evidence=evidence,
    )


def classify_admin_provider(provider: dict[str, Any], source: str) -> FleetLedgerRow:
    return classify_provider_facts(provider, source)


def classify_diagnostics(path: Path) -> FleetLedgerRow:
    payload = json.loads(path.read_text(encoding="utf-8"))
    provider = payload.get("provider", {})
    if not isinstance(provider, dict):
        provider = {}

    provider_logs = _logs(payload, "provider")
    watchdog_logs = _logs(payload, "watchdog")
    all_logs = _all_log_lines(payload)

    home_acl_count, home_acl_path = _count_home_acl(watchdog_logs)
    repair_failed_count = _count_matches(REPAIR_FAILED_RE, all_logs)
    tcp_warning_count = sum(1 for line in watchdog_logs if NO_ESTABLISHED_TCP in line)
    coordinator_tier = _first_match(COORDINATOR_TIER_RE, provider_logs, "tier")
    log_recommended_version = _first_match(NEWER_VERSION_RE, provider_logs, "version")

    provider_id = _string(_first_value(provider, "id", "provider_id"))
    if not provider_id:
        provider_id = _first_match(PROVIDER_ID_RE, provider_logs + watchdog_logs, "id")

    facts = dict(provider)
    facts.update({
        "provider_id": provider_id,
        "hostname": _first_value(provider, "hostname", "host"),
        "malibu_app_version": _first_value(payload, "malibu_version", "app_version"),
        "cli_version": _first_value(provider, "cli_version", "binary_version"),
        "model": _first_value(provider, "model_id", "current_model_id"),
        "trust_tier": _first_value(provider, "trust_tier", "coordinator_tier") or coordinator_tier,
        "coordinator_presence": _presence_from_value(_first_value(provider, "coordinator_connected", "presence")),
        "routing_eligibility": _routing_eligibility(_first_value(provider, "routing_eligible")),
        "last_error": _first_value(provider, "last_error", "error"),
        "_diagnostics_only": True,
    })
    text = _text_blob(facts, all_logs)
    facts["watchdog_repair_state"] = _watchdog_repair_state(text)
    if not facts["last_error"] and repair_failed_count:
        facts["last_error"] = "provider software repair failed"
    if not facts["last_error"] and tcp_warning_count:
        facts["last_error"] = NO_ESTABLISHED_TCP
    if log_recommended_version and not facts.get("recommended_version"):
        facts["recommended_version"] = log_recommended_version

    row = classify_provider_facts(facts, str(path))
    evidence = list(row.evidence)
    if home_acl_count:
        evidence.append(f"watchdog_home_acl_rejections={home_acl_count} path={home_acl_path}")
    if repair_failed_count:
        evidence.append(f"repair_failure_signatures={repair_failed_count}")
    if tcp_warning_count:
        evidence.append(f"watchdog_no_established_tcp_warnings={tcp_warning_count}")
    if log_recommended_version:
        evidence.append(f"provider_log_recommended_version={log_recommended_version}")
    return FleetLedgerRow(**{**row.as_dict(), "evidence": evidence})


def fetch_json(url: str, operator_token: str) -> dict[str, Any]:
    _validate_admin_request_url(url, allow_query=True)
    operator_token = validate_operator_token(operator_token)
    req = Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {operator_token}",
        },
    )
    opener = build_opener(NoRedirectHandler)
    try:
        with opener.open(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as exc:
        raise SystemExit(f"coordinator admin request failed: HTTP {exc.code} for {_safe_request_label(url)}") from exc
    except URLError as exc:
        raise SystemExit(f"coordinator admin request failed: {exc.reason} for {_safe_request_label(url)}") from exc


def fetch_admin_providers(admin_url: str, operator_token: str, limit: int) -> list[dict[str, Any]]:
    base = validate_admin_base_url(admin_url).rstrip("/") + "/"
    after = ""
    after_seen = ""
    providers: list[dict[str, Any]] = []
    while True:
        query = {"limit": str(limit)}
        if after:
            query["after"] = after
        if after_seen:
            query["after_seen"] = after_seen
        payload = fetch_json(urljoin(base, "admin/providers") + "?" + urlencode(query), operator_token)
        batch = payload.get("providers", [])
        if not isinstance(batch, list):
            raise SystemExit("coordinator admin response did not contain providers[]")
        providers.extend(item for item in batch if isinstance(item, dict))
        after = _string(payload.get("next_after"))
        after_seen = _string(payload.get("next_after_seen"))
        if not after or not after_seen:
            return providers


def fetch_poolz(admin_url: str, operator_token: str) -> list[dict[str, Any]]:
    payload = fetch_json(urljoin(validate_admin_base_url(admin_url).rstrip("/") + "/", "poolz"), operator_token)
    pool = payload.get("pool", [])
    if not isinstance(pool, list):
        raise SystemExit("coordinator /poolz response did not contain pool[]")
    return [item for item in pool if isinstance(item, dict)]


def merge_provider_records(
    admin_providers: list[dict[str, Any]],
    poolz_providers: list[dict[str, Any]],
) -> list[tuple[dict[str, Any], str]]:
    merged: dict[str, tuple[dict[str, Any], str]] = {}
    for provider in poolz_providers:
        provider_id = _string(_first_value(provider, "provider_id", "id"))
        if not provider_id:
            continue
        item = dict(provider)
        item.setdefault("presence", "connected")
        merged[provider_id] = (item, "poolz")
    for provider in admin_providers:
        provider_id = _string(_first_value(provider, "provider_id", "id"))
        if not provider_id:
            continue
        item, source = merged.get(provider_id, ({}, ""))
        next_item = dict(item)
        for key, value in provider.items():
            if _has_value(value):
                if source == "poolz" and key in LIVE_POOLZ_TRUTH_KEYS:
                    continue
                next_item[key] = value
        next_source = "admin+poolz" if source == "poolz" else "admin"
        merged[provider_id] = (next_item, next_source)
    return list(merged.values())


def providers_from_response(path: Path, key: str) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    batch = payload.get(key)
    if not isinstance(batch, list):
        raise SystemExit(f"{path} did not contain {key}[]")
    return [item for item in batch if isinstance(item, dict)]


def read_operator_env_file(path: Path, key: str) -> str:
    for line in _read_secret_file(path, "--operator-env-file").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        name, value = stripped.split("=", 1)
        if name.strip() != key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        return value.strip()
    return ""


def resolve_operator_token(
    env_name: str,
    token_file: Path | None = None,
    env_file: Path | None = None,
) -> str:
    if token_file is not None:
        try:
            token = _read_secret_file(token_file, "--operator-token-file")
        except OSError as exc:
            raise SystemExit("--operator-token-file is not readable") from exc
        if token:
            return validate_operator_token(token)
        raise SystemExit("--operator-token-file did not contain a token")
    if env_file is not None:
        try:
            token = read_operator_env_file(env_file, env_name)
        except OSError as exc:
            raise SystemExit("--operator-env-file is not readable") from exc
        if token:
            return validate_operator_token(token)
        raise SystemExit(f"--operator-env-file did not define {env_name}")
    return validate_operator_token(os.environ.get(env_name, "").strip())


def emit_json(rows: list[FleetLedgerRow]) -> None:
    json.dump(
        {
            "bucket_contract": list(USER_BUCKETS),
            "providers": [row.as_dict() for row in rows],
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")


def emit_csv(rows: list[FleetLedgerRow]) -> None:
    fieldnames = [
        "source",
        "provider_id",
        "hostname",
        "malibu_app_version",
        "cli_version",
        "watchdog_repair_state",
        "model",
        "coordinator_presence",
        "routing_eligibility",
        "trust_tier",
        "hash_status",
        "attestation_status",
        "encrypted_leg",
        "catalog_admission_mode",
        "admission_policy_flags",
        "require_hash_verified",
        "require_attestation",
        "require_encrypted_leg",
        "tier2_policy_eligible",
        "tier2_policy_reason",
        "reward_hold_reason",
        "last_heartbeat",
        "last_error",
        "bucket",
        "bucket_reason",
        "operator_next_action",
        "evidence",
    ]
    writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        item = row.as_dict()
        item["evidence"] = "; ".join(row.evidence)
        writer.writerow({field: _csv_safe(item.get(field, "")) for field in fieldnames})


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the #1188 Malibu fleet ledger from coordinator/admin state and fallback diagnostics.",
        epilog="JSON/CSV ledger output is private operator material. Do not commit, attach, or publicly paste it.",
    )
    parser.add_argument("diagnostics", nargs="*", type=Path)
    parser.add_argument(
        "--admin-url",
        help="Coordinator base URL. Pulls /admin/providers and, by default, /poolz.",
    )
    parser.add_argument("--admin-json", type=Path, help="Saved /admin/providers JSON response.")
    parser.add_argument("--poolz-json", type=Path, help="Saved /poolz JSON response.")
    parser.add_argument("--no-poolz", action="store_true", help="Do not augment --admin-url rows with /poolz.")
    parser.add_argument(
        "--operator-token-env",
        default="OPERATOR_KEY",
        help="Environment variable containing the coordinator operator bearer.",
    )
    credential_group = parser.add_mutually_exclusive_group()
    credential_group.add_argument(
        "--operator-token-file",
        type=Path,
        help="File containing the coordinator operator bearer. The value is never printed.",
    )
    credential_group.add_argument(
        "--operator-env-file",
        type=Path,
        help="Env file containing --operator-token-env. The value is never printed.",
    )
    parser.add_argument("--limit", type=int, default=100, help="Coordinator provider page size.")
    parser.add_argument("--format", choices=("json", "csv"), default="json")
    return parser.parse_args(argv)


def rows_from_sources(args: argparse.Namespace) -> list[FleetLedgerRow]:
    rows: list[FleetLedgerRow] = []
    admin_providers: list[dict[str, Any]] = []
    poolz_providers: list[dict[str, Any]] = []

    if args.admin_json:
        admin_providers.extend(providers_from_response(args.admin_json, "providers"))
    if args.poolz_json:
        poolz_providers.extend(providers_from_response(args.poolz_json, "pool"))
    if args.admin_url:
        token = resolve_operator_token(
            args.operator_token_env,
            token_file=args.operator_token_file,
            env_file=args.operator_env_file,
        )
        if not token:
            raise SystemExit(
                f"{args.operator_token_env}, --operator-token-file, or --operator-env-file is required for --admin-url"
            )
        admin_providers.extend(fetch_admin_providers(args.admin_url, token, args.limit))
        if not args.no_poolz:
            poolz_providers.extend(fetch_poolz(args.admin_url, token))

    for provider, source in merge_provider_records(admin_providers, poolz_providers):
        source_name = source
        if args.admin_url and source in ("admin", "admin+poolz"):
            source_name = f"{args.admin_url.rstrip('/')}/admin/providers"
            if source == "admin+poolz":
                source_name += "+/poolz"
        elif args.admin_json and source in ("admin", "admin+poolz"):
            source_name = str(args.admin_json)
            if source == "admin+poolz":
                source_name += f"+{args.poolz_json or 'poolz'}"
        elif args.poolz_json and source == "poolz":
            source_name = str(args.poolz_json)
        rows.append(classify_admin_provider(provider, source_name))

    rows.extend(classify_diagnostics(path) for path in args.diagnostics)
    return sorted(rows, key=lambda row: (row.bucket, row.provider_id, row.source))


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    rows = rows_from_sources(args)
    if not rows:
        raise SystemExit("provide --admin-url, --admin-json, --poolz-json, or diagnostics paths")
    if args.format == "csv":
        emit_csv(rows)
    else:
        emit_json(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
