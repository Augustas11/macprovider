#!/usr/bin/env python3
"""Read-only Pearl coordinator config drift reconciliation.

The tool compares the repo-owned tracked coordinator config with Pearl's live
config files, classifies known differences through source-of-truth.yaml, masks
secret-shaped values, and exits non-zero only for unknown drift.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised only on deficient hosts.
    raise SystemExit("PyYAML is required for Pearl config reconciliation") from exc


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_MANIFEST = REPO_ROOT / "ops/pearl/config/source-of-truth.yaml"
DEFAULT_TRACKED_CONFIG = REPO_ROOT / "phase4-coordinator/dist/coordinator.yaml"

SECRET_FIELD_RE = re.compile(
    r"(^|[._-])(secret|token|keys?|dsn|password|credentials?|hmac)([._-]|$)",
    re.IGNORECASE,
)
ENV_ASSIGNMENT_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")
ENV_REFERENCE_RE = re.compile(r"^env:[A-Za-z_][A-Za-z0-9_]*$")
REMOTE_MALFORMED_ENV_RE = re.compile(r"^__MACPROVIDER_MALFORMED_ENV_LINE_([1-9][0-9]*)=<MASKED>$")
SECRET_VALUE_RE = re.compile(
    r"(?ix)"
    r"("
    r"(?:bearer|basic)\s+\S+"
    r"|(?:sk|pk|rk|ghp|github_pat|xox[baprs]|AKIA)[A-Za-z0-9_=-]{8,}"
    r"|[A-Fa-f0-9]{32,}"
    r"|[A-Za-z0-9_./+=-]{48,}"
    r"|://[^/\s:@]+:[^/\s@]+@"
    r")"
)
SSH_TARGET_RE = re.compile(
    r"^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9_][A-Za-z0-9_.-]*$"
)


@dataclass(frozen=True)
class Drift:
    path: str
    kind: str
    tracked: Any
    live: Any


@dataclass
class Finding:
    category: str
    path: str
    message: str
    owner: str = ""


@dataclass(frozen=True)
class EnvLine:
    key: str | None
    line_no: int
    malformed: bool = False


@dataclass
class ProviderIndex:
    rows: dict[str, dict[str, Any]]
    unknown: list[Finding]


@dataclass
class LiveEvidence:
    config: Any
    overlay: Any
    overlay_present: bool
    env_text: str


def load_yaml_file(path: Path, *, required: bool = True) -> Any:
    if not path.exists():
        if required:
            raise FileNotFoundError(path)
        return {}
    text = path.read_text(encoding="utf-8")
    return load_yaml_text(text, str(path))


def load_yaml_text(text: str, label: str) -> Any:
    try:
        return yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        location = f" at line {mark.line + 1}, column {mark.column + 1}" if mark else ""
        raise SystemExit(f"failed to parse {label}{location}") from exc


def normalize_scalar(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return value


def value_matches(expected: Any, actual: Any) -> bool:
    return normalize_scalar(expected) == normalize_scalar(actual)


def is_secret_path(path: str) -> bool:
    if path.endswith("catalog_public_key") or path.endswith("public_key"):
        return False
    return bool(SECRET_FIELD_RE.search(path))


def is_secret_shaped_value(value: Any) -> bool:
    return isinstance(value, str) and bool(SECRET_VALUE_RE.search(value))


def display_value(path: str, value: Any) -> str:
    if value is _ABSENT:
        return "<ABSENT>"
    if is_secret_path(path):
        if isinstance(value, str) and ENV_REFERENCE_RE.fullmatch(value):
            return value
        return "<MASKED>"
    if is_secret_shaped_value(value):
        return "<MASKED>"
    return repr(value)


def safe_path_segment(value: str) -> str:
    if is_secret_shaped_value(value):
        digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]
        return f"<MASKED:{digest}>"
    return value


def render_safe_path(path: str) -> str:
    parts = re.split(r"([.\[\]])", path)
    return "".join(safe_path_segment(part) if part not in {".", "[", "]"} else part for part in parts)


class _Absent:
    pass


_ABSENT = _Absent()


def strip_providers(config: Any) -> Any:
    if not isinstance(config, dict):
        return config
    clone = copy.deepcopy(config)
    clone.pop("providers", None)
    return clone


def flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    if isinstance(value, dict):
        if not value:
            return {prefix: value}
        out: dict[str, Any] = {}
        for key in sorted(value):
            child = f"{prefix}.{key}" if prefix else str(key)
            out.update(flatten(value[key], child))
        return out
    if isinstance(value, list):
        if not value:
            return {prefix: value}
        out = {}
        for idx, item in enumerate(value):
            child = f"{prefix}[{idx}]"
            out.update(flatten(item, child))
        return out
    return {prefix: value}


def provider_index(config: Any, *, side: str) -> ProviderIndex:
    providers = config.get("providers", []) if isinstance(config, dict) else []
    rows: dict[str, dict[str, Any]] = {}
    unknown: list[Finding] = []
    if not isinstance(providers, list):
        unknown.append(
            Finding(
                category="Unknown",
                path=f"providers.{side}",
                owner="registered_static_providers",
                message="providers section is not a list",
            )
        )
        return ProviderIndex(rows=rows, unknown=unknown)
    for index, row in enumerate(providers):
        path = f"providers.{side}[{index}]"
        if not isinstance(row, dict):
            unknown.append(
                Finding(
                    category="Unknown",
                    path=path,
                    owner="registered_static_providers",
                    message="provider row is not a mapping",
                )
            )
            continue
        provider_id = row.get("provider_id")
        if not isinstance(provider_id, str) or not provider_id:
            unknown.append(
                Finding(
                    category="Unknown",
                    path=path,
                    owner="registered_static_providers",
                    message="provider row is missing a non-empty provider_id",
                )
            )
            continue
        if provider_id in rows:
            unknown.append(
                Finding(
                    category="Unknown",
                    path=f"{path}.provider_id",
                    owner="registered_static_providers",
                    message=f"duplicate provider_id {safe_path_segment(provider_id)!r}",
                )
            )
            continue
        rows[provider_id] = row
    return ProviderIndex(rows=rows, unknown=unknown)


def path_has_prefix(path: str, prefixes: list[str]) -> bool:
    return any(path == prefix or path.startswith(prefix + ".") for prefix in prefixes)


def owner_for_path(path: str, manifest: dict[str, Any]) -> str:
    if is_secret_path(path):
        return "pearl_operator_secrets"
    if path_has_prefix(path, manifest.get("fleet_version_policy_owned_prefixes", [])):
        return "fleet_version_admission_policy"
    if path_has_prefix(path, manifest.get("pearl_overlay_owned_prefixes", [])):
        return "pearl_production_overlay"
    if path_has_prefix(path, manifest.get("tracked_base_owned_prefixes", [])):
        if path == manifest.get("rate_card", {}).get("path") or path.startswith(
            manifest.get("rate_card", {}).get("path", "") + "."
        ):
            return manifest.get("rate_card", {}).get("owner", "tracked_rate_card_source")
        return "base_product_defaults"
    return ""


def compare_flattened(tracked: dict[str, Any], live: dict[str, Any]) -> list[Drift]:
    drifts: list[Drift] = []
    for path in sorted(set(tracked) | set(live)):
        tracked_value = tracked.get(path, _ABSENT)
        live_value = live.get(path, _ABSENT)
        if tracked_value == live_value:
            continue
        if tracked_value is _ABSENT:
            kind = "live_only"
        elif live_value is _ABSENT:
            kind = "tracked_only"
        else:
            kind = "value_mismatch"
        drifts.append(Drift(path=path, kind=kind, tracked=tracked_value, live=live_value))
    return drifts


def known_drift_map(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["path"]: item for item in manifest.get("known_config_drift", [])}


def classify_config_drifts(
    drifts: list[Drift], manifest: dict[str, Any]
) -> tuple[list[Finding], list[Finding], list[Finding]]:
    evidence: list[Finding] = []
    inference: list[Finding] = []
    unknown: list[Finding] = []
    known = known_drift_map(manifest)

    for drift in drifts:
        rule = known.get(drift.path)
        if rule and rule.get("drift_kind") == drift.kind:
            tracked_ok = "tracked" not in rule or value_matches(rule["tracked"], drift.tracked)
            live_ok = "live" not in rule or value_matches(rule["live"], drift.live)
            if tracked_ok and live_ok:
                finding = Finding(
                    category=rule.get("category", "Evidence"),
                    path=drift.path,
                    owner=rule.get("owner", ""),
                    message=(
                        f"{drift.kind}: tracked={display_value(drift.path, drift.tracked)} "
                        f"live={display_value(drift.path, drift.live)}"
                    ),
                )
                if finding.category == "Inference":
                    inference.append(finding)
                else:
                    evidence.append(finding)
                continue
        unknown.append(
            Finding(
                category="Unknown",
                path=drift.path,
                owner=owner_for_path(drift.path, manifest) or "unclassified",
                message=(
                    f"{drift.kind}: tracked={display_value(drift.path, drift.tracked)} "
                    f"live={display_value(drift.path, drift.live)}"
                ),
            )
        )
    return evidence, inference, unknown


def classify_provider_rows(
    tracked: dict[str, dict[str, Any]], live: dict[str, dict[str, Any]], manifest: dict[str, Any]
) -> tuple[list[Finding], list[Finding], list[Finding]]:
    evidence: list[Finding] = []
    inference: list[Finding] = []
    unknown: list[Finding] = []

    provider_rules = manifest.get("provider_rows", {})
    tracked_static = set(provider_rules.get("tracked_static_provider_ids", []))
    pearl_static = set(provider_rules.get("pearl_registered_static_provider_ids", []))
    registered_field_types = provider_rules.get("registered_provider_field_types", {})
    live_only_category = provider_rules.get("live_only_registered_provider_category", "Inference")
    owner = provider_rules.get("owner", "registered_static_providers")

    for provider_id in sorted(set(tracked) | set(live)):
        path = f"providers.{safe_path_segment(provider_id)}"
        if provider_id not in tracked:
            if provider_id in pearl_static:
                finding = Finding(
                    category=live_only_category,
                    path=path,
                    owner=owner,
                    message="live-only provider row is classified as Pearl registered/static provider posture",
                )
                if finding.category == "Evidence":
                    evidence.append(finding)
                else:
                    inference.append(finding)
                unknown.extend(
                    classify_live_only_registered_provider_fields(
                        path,
                        live[provider_id],
                        registered_field_types,
                        owner,
                    )
                )
            else:
                unknown.append(
                    Finding(
                        category="Unknown",
                        path=path,
                        owner="unclassified",
                        message="live-only provider row is not listed in source-of-truth manifest",
                    )
                )
            continue
        if provider_id not in live:
            if provider_id in tracked_static:
                unknown.append(
                    Finding(
                        category="Unknown",
                        path=path,
                        owner=owner,
                        message="tracked static provider row is absent from live config",
                    )
                )
            else:
                unknown.append(
                    Finding(
                        category="Unknown",
                        path=path,
                        owner="unclassified",
                        message="tracked-only provider row is not classified",
                    )
                )
            continue
        if tracked[provider_id] == live[provider_id]:
            evidence.append(
                Finding(
                    category="Evidence",
                    path=path,
                    owner=owner,
                    message="tracked provider row matches live",
                )
            )
            continue
        tracked_flat = flatten(tracked[provider_id])
        live_flat = flatten(live[provider_id])
        row_drifts = compare_flattened(tracked_flat, live_flat)
        for drift in row_drifts:
            drift_path = f"{path}.{drift.path}" if drift.path else path
            unknown.append(
                Finding(
                    category="Unknown",
                    path=drift_path,
                    owner=owner,
                    message=(
                        f"{drift.kind}: tracked={display_provider_drift_value(drift.tracked)} "
                        f"live={display_provider_drift_value(drift.live)}"
                    ),
                )
            )
    return evidence, inference, unknown


def classify_live_only_registered_provider_fields(
    provider_path: str,
    row: dict[str, Any],
    field_types: dict[str, str],
    owner: str,
) -> list[Finding]:
    unknown: list[Finding] = []
    for field, value in sorted(row.items()):
        field_path = f"{provider_path}.{field}"
        expected_type = field_types.get(field)
        if expected_type is None:
            unknown.append(
                Finding(
                    category="Unknown",
                    path=field_path,
                    owner=owner,
                    message="live-only registered provider field is not listed in source-of-truth manifest; value=<MASKED>",
                )
            )
            continue
        if not provider_value_matches_type(value, expected_type):
            unknown.append(
                Finding(
                    category="Unknown",
                    path=field_path,
                    owner=owner,
                    message=(
                        "live-only registered provider field does not match "
                        f"manifest type {expected_type}; value=<MASKED>"
                    ),
                )
            )
    return unknown


def display_provider_drift_value(value: Any) -> str:
    if value is _ABSENT:
        return "<ABSENT>"
    return "<MASKED>"


def provider_value_matches_type(value: Any, expected_type: str) -> bool:
    if expected_type == "string":
        return isinstance(value, str)
    if expected_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected_type == "boolean":
        return isinstance(value, bool)
    if expected_type == "string_list":
        return isinstance(value, list) and all(isinstance(item, str) for item in value)
    return False


def parse_env_lines(text: str) -> list[EnvLine]:
    lines: list[EnvLine] = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        remote_malformed = REMOTE_MALFORMED_ENV_RE.fullmatch(stripped)
        if remote_malformed:
            lines.append(EnvLine(key=None, line_no=int(remote_malformed.group(1)), malformed=True))
            continue
        match = ENV_ASSIGNMENT_RE.match(line)
        if match:
            lines.append(EnvLine(key=match.group(1), line_no=line_no))
        else:
            lines.append(EnvLine(key=None, line_no=line_no, malformed=True))
    return lines


def classify_env_lines(lines: list[EnvLine], manifest: dict[str, Any]) -> tuple[list[Finding], list[Finding]]:
    env_rules = manifest.get("env_key_names", {})
    allowed = set(env_rules.get("allowed", []))
    evidence: list[Finding] = []
    unknown: list[Finding] = []
    seen: set[str] = set()
    for line in lines:
        if line.malformed:
            unknown.append(
                Finding(
                    category="Unknown",
                    path=f"coordinator.env.line_{line.line_no}",
                    owner="unclassified",
                    message="malformed env line is not a KEY=VALUE assignment; value=<MASKED>",
                )
            )
            continue
        key = line.key or ""
        if key in seen:
            unknown.append(
                Finding(
                    category="Unknown",
                    path=f"coordinator.env.{key}",
                    owner="unclassified",
                    message="duplicate env key name is ambiguous; value=<MASKED>",
                )
            )
            continue
        seen.add(key)
        if key in allowed:
            evidence.append(
                Finding(
                    category="Evidence",
                    path=f"coordinator.env.{key}",
                    owner="pearl_operator_secrets",
                    message="key name is classified; value=<MASKED>",
                )
            )
        else:
            unknown.append(
                Finding(
                    category="Unknown",
                    path=f"coordinator.env.{key}",
                    owner="unclassified",
                    message="env key name is not listed in source-of-truth manifest; value=<MASKED>",
                )
            )
    return evidence, unknown


def validate_ssh_target(target: str) -> None:
    if not SSH_TARGET_RE.fullmatch(target):
        raise SystemExit("ssh target must be a conservative alias or user@host")


def run_ssh(target: str, remote_script: str) -> str:
    validate_ssh_target(target)
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        target,
        f"sudo -n sh -c {sh_quote(remote_script)}",
    ]
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        raise SystemExit(f"ssh read timed out for {target}") from exc
    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise SystemExit(f"ssh read failed for {target}: {stderr or 'no stderr'}")
    return result.stdout


def remote_env_inventory_script(env_path: str) -> str:
    quoted_path = sh_quote(env_path)
    return (
        f"test -r {quoted_path} && "
        "awk '"
        "/^[[:space:]]*($|#)/ { next } "
        "/^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { "
        "line=$0; "
        "sub(/^[[:space:]]*(export[[:space:]]+)?/, \"\", line); "
        "sub(/[[:space:]]*=.*/, \"\", line); "
        "print line \"=<MASKED>\"; "
        "next "
        "} "
        "{ print \"__MACPROVIDER_MALFORMED_ENV_LINE_\" NR \"=<MASKED>\" }"
        f"' {quoted_path}"
    )


def read_live_via_ssh(target: str, manifest: dict[str, Any]) -> LiveEvidence:
    files = manifest["pearl"]["files"]
    config_path = files["base_product_defaults"]["live_path"]
    overlay_path = files["production_overlay"]["live_path"]
    env_path = files["secrets_env"]["live_path"]
    config_text = run_ssh(target, f"cat {sh_quote(config_path)}")
    overlay_text = run_ssh(
        target,
        f"test -r {sh_quote(overlay_path)} && cat {sh_quote(overlay_path)} || "
        "printf '__MACPROVIDER_OVERLAY_MISSING__\\n'",
    )
    overlay_present = overlay_text.strip() != "__MACPROVIDER_OVERLAY_MISSING__"
    env_keys_text = run_ssh(target, remote_env_inventory_script(env_path))
    return LiveEvidence(
        config=load_yaml_text(config_text, config_path),
        overlay=load_yaml_text(overlay_text, overlay_path) if overlay_present and overlay_text.strip() else {},
        overlay_present=overlay_present,
        env_text=env_keys_text,
    )


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def summarize_exact_matches(tracked: dict[str, Any], live: dict[str, Any], manifest: dict[str, Any]) -> list[Finding]:
    counts: dict[str, int] = {}
    for path, tracked_value in tracked.items():
        if path in live and live[path] == tracked_value:
            owner = owner_for_path(path, manifest) or "unclassified_equal"
            counts[owner] = counts.get(owner, 0) + 1
    return [
        Finding(
            category="Evidence",
            path=f"summary.{owner}",
            owner=owner,
            message=f"{count} tracked/live scalar fields match",
        )
        for owner, count in sorted(counts.items())
    ]


def classify_overlay(live_overlay: Any, manifest: dict[str, Any]) -> tuple[list[Finding], list[Finding]]:
    evidence: list[Finding] = []
    unknown: list[Finding] = []
    if live_overlay is None or live_overlay == {} or live_overlay == []:
        return evidence, unknown
    overlay_flat = flatten(live_overlay)
    if not overlay_flat:
        return evidence, unknown
    prefixes = manifest.get("pearl_overlay_owned_prefixes", [])
    for path in sorted(overlay_flat):
        finding_path = f"production_overlay.{path}"
        if path_has_prefix(path, prefixes):
            evidence.append(
                Finding(
                    category="Evidence",
                    path=finding_path,
                    owner="pearl_production_overlay",
                    message="live overlay field is classified; value=<MASKED>",
                )
            )
        else:
            unknown.append(
                Finding(
                    category="Unknown",
                    path=finding_path,
                    owner="unclassified",
                    message="live overlay field is not listed in source-of-truth manifest; value=<MASKED>",
                )
            )
    return evidence, unknown


def render_findings(evidence: list[Finding], inference: list[Finding], unknown: list[Finding]) -> str:
    lines = [
        "Pearl config reconciliation (read-only)",
        "",
        "Evidence:",
    ]
    lines.extend(render_category(evidence))
    lines.extend(["", "Inference:"])
    lines.extend(render_category(inference))
    lines.extend(["", "Unknown:"])
    lines.extend(render_category(unknown))
    return "\n".join(lines) + "\n"


def render_category(findings: list[Finding]) -> list[str]:
    if not findings:
        return ["- none"]
    lines: list[str] = []
    for finding in findings:
        owner = f" [{finding.owner}]" if finding.owner else ""
        lines.append(f"- {render_safe_path(finding.path)}: {finding.message}{owner}")
    return lines


def reconcile(
    *,
    manifest_path: Path,
    tracked_config_path: Path,
    live_config_path: Path | None,
    live_overlay_path: Path | None,
    live_env_path: Path | None,
    ssh_target: str | None,
) -> tuple[str, int]:
    manifest = load_yaml_file(manifest_path)
    tracked_config = load_yaml_file(tracked_config_path)

    if ssh_target:
        live_evidence = read_live_via_ssh(ssh_target, manifest)
        live_config = live_evidence.config
        live_overlay = live_evidence.overlay
        live_overlay_present = live_evidence.overlay_present
        live_env_text = live_evidence.env_text
    else:
        if live_config_path is None:
            raise SystemExit("either --live-config or --ssh-target is required")
        if live_env_path is None:
            raise SystemExit("--live-env is required when not using --ssh-target")
        live_config = load_yaml_file(live_config_path)
        live_overlay = load_yaml_file(live_overlay_path, required=False) if live_overlay_path else {}
        live_overlay_present = live_overlay_path is not None and live_overlay_path.exists()
        live_env_text = live_env_path.read_text(encoding="utf-8")

    tracked_flat = flatten(strip_providers(tracked_config))
    live_flat = flatten(strip_providers(live_config))
    config_drifts = compare_flattened(tracked_flat, live_flat)

    evidence = summarize_exact_matches(tracked_flat, live_flat, manifest)
    drift_evidence, drift_inference, drift_unknown = classify_config_drifts(config_drifts, manifest)
    evidence.extend(drift_evidence)
    inference = drift_inference
    unknown = drift_unknown

    tracked_providers = provider_index(tracked_config, side="tracked")
    live_providers = provider_index(live_config, side="live")
    unknown.extend(tracked_providers.unknown)
    unknown.extend(live_providers.unknown)
    provider_evidence, provider_inference, provider_unknown = classify_provider_rows(
        tracked_providers.rows, live_providers.rows, manifest
    )
    evidence.extend(provider_evidence)
    inference.extend(provider_inference)
    unknown.extend(provider_unknown)

    overlay_evidence, overlay_unknown = classify_overlay(live_overlay, manifest)
    if not live_overlay_present:
        unknown.append(
            Finding(
                category="Unknown",
                path="production_overlay",
                owner="pearl_production_overlay",
                message="overlay evidence file is missing or unreadable",
            )
        )
    elif overlay_evidence or overlay_unknown:
        evidence.extend(overlay_evidence)
        unknown.extend(overlay_unknown)
    else:
        inference.append(
            Finding(
                category="Inference",
                path="production_overlay",
                owner="pearl_production_overlay",
                message="overlay file absent or empty in provided evidence",
            )
        )

    env_evidence, env_unknown = classify_env_lines(parse_env_lines(live_env_text), manifest)
    evidence.extend(env_evidence)
    unknown.extend(env_unknown)

    evidence.sort(key=lambda item: item.path)
    inference.sort(key=lambda item: item.path)
    unknown.sort(key=lambda item: item.path)
    return render_findings(evidence, inference, unknown), 1 if unknown else 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--tracked-config", type=Path, default=DEFAULT_TRACKED_CONFIG)
    parser.add_argument("--live-config", type=Path)
    parser.add_argument("--live-overlay", type=Path)
    parser.add_argument("--live-env", type=Path)
    parser.add_argument("--ssh-target", help="SSH target such as pearl; read-only")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    output, rc = reconcile(
        manifest_path=args.manifest,
        tracked_config_path=args.tracked_config,
        live_config_path=args.live_config,
        live_overlay_path=args.live_overlay,
        live_env_path=args.live_env,
        ssh_target=args.ssh_target,
    )
    sys.stdout.write(output)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
