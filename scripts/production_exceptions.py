#!/usr/bin/env python3
"""#615 production exception register loader, validator, report, and gates.

Dependency-free (stdlib only). Validates ops/exceptions/production-exceptions.json
against the committed schema's structural rules, enforces unique IDs / ownership /
expiry fail-closed behavior, emits an operator report without secrets, and gates
deploy / stable-promotion when configured.

Default-safe deploy behavior (MACPROVIDER_EXCEPTION_ENFORCEMENT unset/0):
  - Hard-fail: malformed register, duplicate IDs, ownerless rows, scope/environment
    mismatch, active rows past expires_at, resurrection of tombstoned IDs,
    removed rows without tombstones, tombstone deletions vs a provided base.
  - Warn only: status=expired rows, active rows with expires_at=null,
    approaching-expiry alerts, blocks_stable_promotion=true rows.

Enforcement (MACPROVIDER_EXCEPTION_ENFORCEMENT=1) or --mode=promote:
  - All hard-fails above, plus status=expired, active null-expiry,
    approaching-expiry (within alert window), and blocks_stable_promotion=true
    for active/planned/expired rows become hard-fails.

These gates enforce registered-row policy only. They do not discover unregistered
live Pearl/config/DB exceptions; that remains an open #615 item.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from copy import deepcopy
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = "macprovider-production-exceptions-v1"
TOMBSTONE_SCHEMA_VERSION = "macprovider-removed-exception-tombstones-v1"
ENVIRONMENT = "pearl-production"
STATUSES = frozenset({"active", "expired", "removed", "planned"})
COMPONENTS = frozenset(
    {
        "coordinator",
        "gateway",
        "cli",
        "malibu",
        "pearl-canary",
        "catalog",
        "tier2",
        "edge",
        "other",
    }
)
ISSUE_RE = re.compile(
    r"^(#[0-9]+|https://github\.com/Augustas11/macprovider/issues/[0-9]+)$"
)
ID_RE = re.compile(r"^exc-[a-z0-9]+(?:-[a-z0-9]+)*$")
OQ_ID_RE = re.compile(r"^oq-[a-z0-9]+(?:-[a-z0-9]+)*$")
RFC3339_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
OWNER_PLACEHOLDER_RE = re.compile(
    r"(?i)(^|\b)(tbd|todo|unknown|unowned|n/?a|none|owner|\?\?\?)(\b|$)|^\s*$"
)
SECRET_RE = re.compile(
    r"(?is)("
    # Full Authorization credential forms must win before any shorter overlap.
    r"authorization\s*[:=]\s*basic\s+\S+|"
    r"authorization\s*[:=]\s*bearer\s+\S+|"
    r"authorization\s*[:=]\s*\S+|"
    r"basic\s+[a-z0-9+/]+=*|"
    r"bearer\s+[a-z0-9._\-+=/]+|"
    r"sk-[a-z0-9]{10,}|"
    r"ghp_[a-z0-9]{20,}|"
    r"akia[0-9a-z]{16}|"
    r"eyj[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+|"
    r"xox[baprs]-[a-z0-9-]{10,}|"
    r"-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----|"
    r"api[_-]?key\s*[:=]\s*\S+|"
    r"password\s*[:=]\s*\S+|"
    r"token\s*[:=]\s*\S+|"
    r"\b[a-f0-9]{64}\b"
    r")"
)
# Residual scan is intentionally broader than the redaction transform so a
# transform miss cannot certify secrets_redacted=true.
RESIDUAL_SECRET_RE = re.compile(
    r"(?is)("
    r"authorization\s*[:=]\s*\S+|"
    r"\bbasic\s+\S+|"
    r"\bbearer\s+\S+|"
    r"sk-[a-z0-9]{8,}|"
    r"ghp_[a-z0-9]{16,}|"
    r"akia[0-9a-z]{12,}|"
    r"eyj[a-z0-9_-]+\.[a-z0-9_-]+|"
    r"xox[baprs]-[a-z0-9-]{8,}|"
    r"-----BEGIN[^-]*PRIVATE KEY-----|"
    r"api[_-]?key\s*[:=]\s*\S+|"
    r"password\s*[:=]\s*\S+|"
    r"token\s*[:=]\s*\S+|"
    r"\b[a-f0-9]{64}\b"
    r")"
)
REGISTER_ROOT_KEYS = frozenset(
    {
        "$schema",
        "schema_version",
        "updated_at",
        "updated_by",
        "environment",
        "exceptions",
        "open_questions",
    }
)
EXCEPTION_KEYS = frozenset(REQUIRED_EXCEPTION_FIELDS := (
    "id",
    "status",
    "environment",
    "component",
    "policy_delta",
    "authority_surface",
    "reason",
    "owner",
    "issue",
    "created_at",
    "expires_at",
    "scope",
    "removal_condition",
    "rollback_command",
    "post_removal_validation",
    "blocks_stable_promotion",
    "evidence",
)) | {
    "expiry_unknown_reason",
    # Optional #608 progress notes — durable clearance tracking, not free-form
    # arbitrary keys. Present as arrays of non-empty strings when used.
    "partial_progress",
    "still_blocked_for_clearance",
}
OPTIONAL_STRING_LIST_FIELDS = frozenset(
    {"partial_progress", "still_blocked_for_clearance"}
)
OPEN_QUESTION_KEYS = frozenset(
    {"id", "question", "owner", "status", "evidence_target"}
)
TOMBSTONE_ROOT_KEYS = frozenset(
    {
        "schema_version",
        "updated_at",
        "updated_by",
        "environment",
        "tombstones",
        "notes",
    }
)
TOMBSTONE_ENTRY_KEYS = frozenset(
    {"id", "removed_at", "removal_evidence", "authority_surface"}
)
DEFAULT_ALERT_HOURS = 72
WIDE_SCOPE_RE = re.compile(
    r"(?i)(\b(all providers|every provider|global (production )?fleet|entire fleet)\b|(?<![^\s])\*(?![^\s]))"
)


@dataclass
class Finding:
    severity: str  # error | warn
    code: str
    message: str
    exception_id: str | None = None

    def format(self) -> str:
        loc = redact_secrets(self.exception_id or "<register>")
        return f"{self.severity.upper()} {self.code} {loc}: {redact_secrets(self.message)}"


@dataclass
class ValidationResult:
    findings: list[Finding] = field(default_factory=list)

    def error(self, code: str, message: str, exception_id: str | None = None) -> None:
        self.findings.append(Finding("error", code, message, exception_id))

    def warn(self, code: str, message: str, exception_id: str | None = None) -> None:
        self.findings.append(Finding("warn", code, message, exception_id))

    @property
    def errors(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "error"]

    @property
    def warnings(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "warn"]

    def extend(self, other: "ValidationResult") -> None:
        self.findings.extend(other.findings)

    def dedupe(self) -> "ValidationResult":
        seen: set[tuple[str, str, str | None]] = set()
        out = ValidationResult()
        for finding in self.findings:
            key = (finding.severity, finding.code, finding.exception_id)
            if key in seen:
                continue
            seen.add(key)
            out.findings.append(finding)
        return out


def repo_root_from_here() -> Path:
    return Path(__file__).resolve().parent.parent


def default_register_path(root: Path | None = None) -> Path:
    return (root or repo_root_from_here()) / "ops/exceptions/production-exceptions.json"


def default_tombstone_path(root: Path | None = None) -> Path:
    return (root or repo_root_from_here()) / "ops/exceptions/removed-exception-tombstones.json"


def default_schema_path(root: Path | None = None) -> Path:
    return (root or repo_root_from_here()) / "ops/exceptions/production-exceptions.schema.json"


def parse_rfc3339(value: str) -> datetime:
    if not isinstance(value, str) or not RFC3339_RE.fullmatch(value):
        raise ValueError(f"not RFC3339Z: {value!r}")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def redact_secrets(text: str) -> str:
    return SECRET_RE.sub("[REDACTED]", text)


def contains_secret(text: str) -> bool:
    return bool(SECRET_RE.search(text))


def contains_residual_secret(text: str) -> bool:
    """Broader residual detector used only for secrets_redacted assurance."""
    return bool(RESIDUAL_SECRET_RE.search(text))


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"missing file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {path}: {exc}") from exc


def _owner_ok(owner: Any) -> bool:
    if not isinstance(owner, str):
        return False
    cleaned = owner.strip()
    if not cleaned:
        return False
    return OWNER_PLACEHOLDER_RE.search(cleaned) is None


def _scope_ok(entry: dict[str, Any], register_env: str) -> str | None:
    if entry.get("environment") != register_env:
        return (
            f"exception environment {entry.get('environment')!r} mismatches "
            f"register environment {register_env!r}"
        )
    scope = entry.get("scope")
    if not isinstance(scope, str) or not scope.strip():
        return "scope must be a non-empty string"
    component = entry.get("component")
    if component not in COMPONENTS:
        return f"component {component!r} is not in the allowed set"
    # Heuristic only — semantic scope bounds remain partially open (#615).
    if entry.get("status") in {"active", "planned"}:
        lowered = scope.lower()
        if WIDE_SCOPE_RE.search(lowered) and "must not widen" not in lowered:
            return (
                "scope appears globally widened without an explicit "
                "'must not widen' bound (heuristic)"
            )
        if "arbitrary" in lowered:
            prohibited = (
                "must not" in lowered
                or "no arbitrary" in lowered
                or "not arbitrary" in lowered
                or "without arbitrary" in lowered
            )
            if not prohibited:
                return "scope mentions arbitrary widening without an explicit prohibition"
    return None


def validate_register(
    doc: dict[str, Any],
    *,
    now: datetime | None = None,
    tombstones: dict[str, Any] | None = None,
    alert_hours: int = DEFAULT_ALERT_HOURS,
    previous_doc: dict[str, Any] | None = None,
    base_tombstones: dict[str, Any] | None = None,
) -> ValidationResult:
    result = ValidationResult()
    now = now or datetime.now(timezone.utc)
    if not isinstance(doc, dict):
        result.error("register_type", "register root must be an object")
        return result

    unknown_root = sorted(set(doc) - REGISTER_ROOT_KEYS)
    if unknown_root:
        result.error("additional_properties", f"unknown root fields: {unknown_root}")

    if doc.get("schema_version") != SCHEMA_VERSION:
        result.error(
            "schema_version",
            f"schema_version must be {SCHEMA_VERSION!r}, got {doc.get('schema_version')!r}",
        )
    if doc.get("environment") != ENVIRONMENT:
        result.error(
            "environment",
            f"environment must be {ENVIRONMENT!r}, got {doc.get('environment')!r}",
        )
    updated_at = doc.get("updated_at")
    try:
        parse_rfc3339(updated_at)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        result.error("updated_at", "updated_at must be a valid RFC3339Z timestamp")
    if not isinstance(doc.get("updated_by"), str) or not doc.get("updated_by", "").strip():
        result.error("updated_by", "updated_by must be a non-empty string")
    if "$schema" not in doc or not isinstance(doc.get("$schema"), str) or not doc["$schema"]:
        result.error("$schema", "$schema must be a non-empty string")

    exceptions = doc.get("exceptions")
    if not isinstance(exceptions, list) or not exceptions:
        result.error("exceptions", "exceptions must be a non-empty array")
        return result

    ids: list[str] = []
    for index, entry in enumerate(exceptions):
        loc = f"exceptions[{index}]"
        if not isinstance(entry, dict):
            result.error("entry_type", f"{loc} must be an object")
            continue
        unknown = sorted(set(entry) - EXCEPTION_KEYS)
        if unknown:
            result.error("additional_properties", f"unknown fields: {unknown}", loc)
        exc_id = entry.get("id") if isinstance(entry.get("id"), str) else loc
        missing = [key for key in REQUIRED_EXCEPTION_FIELDS if key not in entry]
        if missing:
            result.error("required_fields", f"missing fields: {missing}", exc_id)
        if not isinstance(entry.get("id"), str) or not ID_RE.fullmatch(entry["id"]):
            result.error("id_format", f"id must match {ID_RE.pattern}", exc_id)
        else:
            ids.append(entry["id"])
        if entry.get("status") not in STATUSES:
            result.error("status", f"invalid status {entry.get('status')!r}", exc_id)
        if entry.get("environment") != ENVIRONMENT:
            result.error("environment", f"environment must be {ENVIRONMENT!r}", exc_id)
        if entry.get("component") not in COMPONENTS:
            result.error("component", f"invalid component {entry.get('component')!r}", exc_id)
        for text_field in (
            "policy_delta",
            "authority_surface",
            "reason",
            "scope",
            "removal_condition",
            "rollback_command",
            "post_removal_validation",
        ):
            value = entry.get(text_field)
            if not isinstance(value, str) or not value.strip():
                result.error(text_field, f"{text_field} must be a non-empty string", exc_id)
        if not _owner_ok(entry.get("owner")):
            result.error("ownerless", "owner is missing or placeholder", exc_id)
        if not isinstance(entry.get("issue"), str) or not ISSUE_RE.fullmatch(entry["issue"]):
            result.error("issue", "issue must be #N or the canonical GitHub issue URL", exc_id)
        if not isinstance(entry.get("blocks_stable_promotion"), bool):
            result.error(
                "blocks_stable_promotion",
                "blocks_stable_promotion must be a boolean",
                exc_id,
            )
        evidence = entry.get("evidence")
        if not isinstance(evidence, list):
            result.error("evidence", "evidence must be an array", exc_id)
        else:
            for evid_index, item in enumerate(evidence):
                if not isinstance(item, str) or not item.strip():
                    result.error(
                        "evidence",
                        f"evidence[{evid_index}] must be a non-empty string",
                        exc_id,
                    )

        for list_field in sorted(OPTIONAL_STRING_LIST_FIELDS):
            if list_field not in entry:
                continue
            value = entry.get(list_field)
            if not isinstance(value, list):
                result.error(list_field, f"{list_field} must be an array when present", exc_id)
                continue
            for item_index, item in enumerate(value):
                if not isinstance(item, str) or not item.strip():
                    result.error(
                        list_field,
                        f"{list_field}[{item_index}] must be a non-empty string",
                        exc_id,
                    )

        created_at = entry.get("created_at")
        if created_at is not None:
            try:
                parse_rfc3339(created_at)
            except (TypeError, ValueError):
                result.error("created_at", "created_at must be RFC3339Z or null", exc_id)

        expires_at = entry.get("expires_at")
        expiry_unknown = entry.get("expiry_unknown_reason")
        if "expiry_unknown_reason" in entry and (
            not isinstance(expiry_unknown, str) or not expiry_unknown.strip()
        ):
            result.error(
                "expiry_unknown",
                "expiry_unknown_reason must be a non-empty string when present",
                exc_id,
            )
        if expires_at is None:
            if not isinstance(expiry_unknown, str) or not expiry_unknown.strip():
                result.error(
                    "expiry_unknown",
                    "expires_at is null but expiry_unknown_reason is missing",
                    exc_id,
                )
            if entry.get("status") == "active":
                result.warn(
                    "unbounded_active",
                    "active exception has expires_at=null; set a bounded expiry from evidence",
                    exc_id,
                )
        else:
            try:
                expiry = parse_rfc3339(expires_at)
            except (TypeError, ValueError):
                result.error("expires_at", "expires_at must be RFC3339Z or null", exc_id)
            else:
                if entry.get("status") == "active" and expiry <= now:
                    result.error(
                        "expired_active",
                        f"active exception is past expires_at={expires_at} (fail-closed)",
                        exc_id,
                    )
                elif entry.get("status") == "active" and expiry <= now + timedelta(
                    hours=alert_hours
                ):
                    result.warn(
                        "expiry_soon",
                        f"active exception expires at {expires_at} (within {alert_hours}h)",
                        exc_id,
                    )

        if entry.get("status") == "expired":
            result.warn(
                "status_expired",
                "exception is marked expired; stable promotion and enforced deploy must reject it",
                exc_id,
            )

        if (
            entry.get("blocks_stable_promotion") is True
            and entry.get("status") in {"active", "planned", "expired"}
        ):
            result.warn(
                "blocks_stable_promotion",
                "blocks_stable_promotion=true; stable promotion must reject this row",
                exc_id,
            )

        scope_err = _scope_ok(entry, ENVIRONMENT)
        if scope_err:
            result.error("scope_mismatch", scope_err, exc_id)

    dupes = sorted({item for item in ids if ids.count(item) > 1})
    if dupes:
        result.error("duplicate_ids", f"duplicate exception ids: {dupes}")

    open_questions = doc.get("open_questions")
    if not isinstance(open_questions, list):
        result.error("open_questions", "open_questions must be an array")
    else:
        oq_ids: list[str] = []
        for index, item in enumerate(open_questions):
            if not isinstance(item, dict):
                result.error("open_question_type", f"open_questions[{index}] must be an object")
                continue
            unknown = sorted(set(item) - OPEN_QUESTION_KEYS)
            if unknown:
                result.error(
                    "additional_properties",
                    f"unknown open_question fields: {unknown}",
                    f"open_questions[{index}]",
                )
            oq_id = item.get("id") if isinstance(item.get("id"), str) else f"open_questions[{index}]"
            for key in ("id", "question", "owner", "status", "evidence_target"):
                if key not in item:
                    result.error("open_question_fields", f"missing {key}", oq_id)
            if isinstance(item.get("id"), str):
                if not OQ_ID_RE.fullmatch(item["id"]):
                    result.error("open_question_id", "invalid open-question id", oq_id)
                else:
                    oq_ids.append(item["id"])
            for text_key in ("question", "evidence_target"):
                value = item.get(text_key)
                if not isinstance(value, str) or not value.strip():
                    result.error(text_key, f"{text_key} must be a non-empty string", oq_id)
            if not _owner_ok(item.get("owner")):
                result.error("ownerless", "open question owner is missing or placeholder", oq_id)
            if item.get("status") not in {"pending", "answered"}:
                result.error("open_question_status", f"invalid status {item.get('status')!r}", oq_id)
        oq_dupes = sorted({item for item in oq_ids if oq_ids.count(item) > 1})
        if oq_dupes:
            result.error("duplicate_oq_ids", f"duplicate open_question ids: {oq_dupes}")

    tombstone_ids: set[str] = set()
    if tombstones is not None:
        tombstone_ids = validate_tombstones(tombstones, result)

    for entry in exceptions:
        if not isinstance(entry, dict):
            continue
        exc_id = entry.get("id")
        if not isinstance(exc_id, str):
            continue
        if entry.get("status") == "removed" and exc_id not in tombstone_ids:
            result.error(
                "missing_tombstone",
                "removed exception lacks a tombstone entry",
                exc_id,
            )
        if exc_id in tombstone_ids and entry.get("status") != "removed":
            result.error(
                "resurrection",
                "tombstoned exception id reappears with non-removed status",
                exc_id,
            )

    if base_tombstones is not None:
        base_ids = validate_tombstones(base_tombstones, result)
        deleted = sorted(base_ids - tombstone_ids)
        if deleted:
            result.error(
                "tombstone_deleted",
                f"tombstone ids removed vs trusted base: {deleted}",
            )

    if previous_doc is not None:
        check_anti_resurrection(previous_doc, doc, tombstone_ids, result)
        check_expiry_self_extension(previous_doc, doc, result)
        check_expired_reactivation(previous_doc, doc, result)

    return result.dedupe()


def validate_tombstones(doc: dict[str, Any], result: ValidationResult | None = None) -> set[str]:
    result = result or ValidationResult()
    ids: set[str] = set()
    if not isinstance(doc, dict):
        result.error("tombstone_type", "tombstone root must be an object")
        return ids
    unknown = sorted(set(doc) - TOMBSTONE_ROOT_KEYS)
    if unknown:
        result.error("tombstone_additional", f"unknown tombstone root fields: {unknown}")
    if doc.get("schema_version") != TOMBSTONE_SCHEMA_VERSION:
        result.error(
            "tombstone_schema",
            f"tombstone schema_version must be {TOMBSTONE_SCHEMA_VERSION!r}",
        )
    if doc.get("environment") != ENVIRONMENT:
        result.error("tombstone_environment", f"environment must be {ENVIRONMENT!r}")
    try:
        parse_rfc3339(doc.get("updated_at"))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        result.error("tombstone_updated_at", "updated_at must be RFC3339Z")
    rows = doc.get("tombstones")
    if not isinstance(rows, list):
        result.error("tombstones", "tombstones must be an array")
        return ids
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            result.error("tombstone_entry", f"tombstones[{index}] must be an object")
            continue
        unknown_row = sorted(set(row) - TOMBSTONE_ENTRY_KEYS)
        if unknown_row:
            result.error(
                "tombstone_additional",
                f"unknown tombstone fields: {unknown_row}",
                f"tombstones[{index}]",
            )
        exc_id = row.get("id")
        if not isinstance(exc_id, str) or not ID_RE.fullmatch(exc_id):
            result.error("tombstone_id", f"tombstones[{index}].id is invalid")
            continue
        if exc_id in ids:
            result.error("tombstone_duplicate", f"duplicate tombstone id {exc_id}")
        ids.add(exc_id)
        try:
            parse_rfc3339(row.get("removed_at"))  # type: ignore[arg-type]
        except (TypeError, ValueError):
            result.error("tombstone_removed_at", "removed_at must be RFC3339Z", exc_id)
        if not isinstance(row.get("removal_evidence"), str) or not row["removal_evidence"].strip():
            result.error("tombstone_evidence", "removal_evidence required", exc_id)
        if not isinstance(row.get("authority_surface"), str) or not row["authority_surface"].strip():
            result.error("tombstone_authority", "authority_surface required", exc_id)
    return ids


def check_anti_resurrection(
    previous_doc: dict[str, Any],
    next_doc: dict[str, Any],
    tombstone_ids: set[str],
    result: ValidationResult,
) -> None:
    prev_by_id = {
        entry["id"]: entry
        for entry in previous_doc.get("exceptions", [])
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    for entry in next_doc.get("exceptions", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            continue
        exc_id = entry["id"]
        resurrecting = entry.get("status") in {"active", "planned", "expired"}
        if not resurrecting:
            continue
        if exc_id in tombstone_ids:
            result.error(
                "resurrection",
                "config/register sync would restore a tombstoned exception id",
                exc_id,
            )
        prev = prev_by_id.get(exc_id)
        if prev is not None and prev.get("status") == "removed":
            result.error(
                "resurrection",
                "removed exception id was restored from a non-removed status",
                exc_id,
            )


def check_expiry_self_extension(
    previous_doc: dict[str, Any],
    next_doc: dict[str, Any],
    result: ValidationResult,
) -> None:
    """Reject silent expires_at extensions when a previous register is supplied."""
    prev_by_id = {
        entry["id"]: entry
        for entry in previous_doc.get("exceptions", [])
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    for entry in next_doc.get("exceptions", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            continue
        prev = prev_by_id.get(entry["id"])
        if prev is None:
            continue
        prev_exp = prev.get("expires_at")
        next_exp = entry.get("expires_at")
        if not isinstance(prev_exp, str) or not isinstance(next_exp, str):
            continue
        try:
            prev_dt = parse_rfc3339(prev_exp)
            next_dt = parse_rfc3339(next_exp)
        except ValueError:
            continue
        if next_dt > prev_dt and entry.get("status") in {"active", "planned"}:
            result.error(
                "expiry_self_extension",
                f"expires_at moved later from {prev_exp} to {next_exp} without a new exception id",
                entry["id"],
            )


def validate_stale_register(
    doc: dict[str, Any],
    result: ValidationResult,
    now: datetime | None = None,
) -> None:
    """Structural validation for a stale/backup register before sync simulation.

    Historical mode: do not require tombstones for removed rows (stale may
    predate the tombstone ledger), but still reject malformed authority.
    """
    if not isinstance(doc, dict):
        result.error("stale_type", "stale register must be an object")
        return
    # Full structural validation, then drop historical-only missing_tombstone
    # findings that cannot apply to pre-tombstone backups.
    historical = validate_register(
        doc,
        now=now,
        tombstones={
            "schema_version": TOMBSTONE_SCHEMA_VERSION,
            "updated_at": "1970-01-01T00:00:00Z",
            "updated_by": "historical",
            "environment": ENVIRONMENT,
            "tombstones": [],
        },
    )
    for finding in historical.findings:
        if finding.code == "missing_tombstone":
            continue
        # Remap codes so operators see these as stale-authority failures.
        code = finding.code if finding.code.startswith("stale_") else f"stale_{finding.code}"
        if finding.severity == "error":
            result.error(code, finding.message, finding.exception_id)
        else:
            result.warn(code, finding.message, finding.exception_id)


def simulate_config_sync_restore(
    current_doc: dict[str, Any],
    stale_authoritative_doc: dict[str, Any],
    tombstones: dict[str, Any],
    now: datetime | None = None,
) -> ValidationResult:
    """Model a sync/rollback that re-applies stale authoritative exception rows."""
    result = ValidationResult()
    result.extend(validate_register(current_doc, now=now, tombstones=tombstones))
    validate_stale_register(stale_authoritative_doc, result, now=now)
    if result.errors:
        # Malformed current/stale/tombstones already fail closed; do not pretend OK.
        return result.dedupe()

    merged = deepcopy(current_doc)
    by_id = {
        entry["id"]: entry
        for entry in merged.get("exceptions", [])
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    for entry in stale_authoritative_doc.get("exceptions", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            continue
        by_id[entry["id"]] = deepcopy(entry)
    merged["exceptions"] = list(by_id.values())
    tombstone_ids = validate_tombstones(tombstones, result)
    check_anti_resurrection(current_doc, merged, tombstone_ids, result)
    for entry in merged.get("exceptions", []):
        if not isinstance(entry, dict):
            continue
        exc_id = entry.get("id")
        if (
            isinstance(exc_id, str)
            and exc_id in tombstone_ids
            and entry.get("status") != "removed"
        ):
            result.error(
                "resurrection",
                "stale authoritative sync restored a tombstoned exception",
                exc_id,
            )
    return result.dedupe()


REPORT_ROW_KEYS = frozenset(
    {
        "id",
        "status",
        "component",
        "issue",
        "expires_at",
        "clock_state",
        "blocks_stable_promotion",
    }
)
# Free-prose inventory fields intentionally omitted from reports so
# secrets_redacted is a claim over a closed field set (enums / IDs /
# timestamps / bools), not over owner/reason/scope/policy strings.
REPORT_OMITTED_FIELDS = frozenset(
    {
        "owner",
        "policy_delta",
        "authority_surface",
        "reason",
        "scope",
        "partial_progress",
        "still_blocked_for_clearance",
    }
)


def union_tombstone_docs(history: Iterable[dict[str, Any] | None]) -> dict[str, Any]:
    """Union tombstone rows across history; first-seen metadata wins."""
    by_id: dict[str, dict[str, Any]] = {}
    for doc in history:
        if not isinstance(doc, dict):
            continue
        rows = doc.get("tombstones")
        if not isinstance(rows, list):
            continue
        for row in rows:
            if isinstance(row, dict) and isinstance(row.get("id"), str):
                by_id.setdefault(row["id"], row)
    return {
        "schema_version": TOMBSTONE_SCHEMA_VERSION,
        "updated_at": "1970-01-01T00:00:00Z",
        "updated_by": "promote-history-union",
        "environment": ENVIRONMENT,
        "tombstones": list(by_id.values()),
    }


def earliest_expiry_previous_register(
    current: dict[str, Any],
    history: Iterable[dict[str, Any] | None],
) -> dict[str, Any]:
    """Rebuild previous register with the earliest parseable expires_at per ID.

    Includes active/planned/expired historical rows. Any historical `expired`
    observation for an ID is restored onto the previous row when the tip is
    active/planned, so active→expired→active reactivation cannot erase the
    expired intermediate state by selecting an earlier equal-dated active row.
    """
    earliest: dict[str, tuple[datetime, str]] = {}
    saw_expired: set[str] = set()
    for doc in history:
        if not isinstance(doc, dict):
            continue
        rows = doc.get("exceptions")
        if not isinstance(rows, list):
            continue
        for entry in rows:
            if not isinstance(entry, dict):
                continue
            exc_id = entry.get("id")
            expires = entry.get("expires_at")
            status = entry.get("status")
            if not isinstance(exc_id, str) or status not in {"active", "planned", "expired"}:
                continue
            if status == "expired":
                saw_expired.add(exc_id)
            if not isinstance(expires, str):
                continue
            try:
                exp_dt = parse_rfc3339(expires)
            except ValueError:
                continue
            prev = earliest.get(exc_id)
            if prev is None or exp_dt < prev[0]:
                earliest[exc_id] = (exp_dt, expires)

    previous = deepcopy(current)
    for entry in previous.get("exceptions", []):
        if not isinstance(entry, dict):
            continue
        exc_id = entry.get("id")
        if not isinstance(exc_id, str):
            continue
        if exc_id in earliest:
            entry["expires_at"] = earliest[exc_id][1]
        if exc_id in saw_expired and entry.get("status") in {"active", "planned"}:
            entry["status"] = "expired"
    return previous


def check_expired_reactivation(
    previous_doc: dict[str, Any],
    next_doc: dict[str, Any],
    result: ValidationResult,
) -> None:
    """Reject same-ID expired -> active/planned transitions without a new ID."""
    prev_by_id = {
        entry["id"]: entry
        for entry in previous_doc.get("exceptions", [])
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    for entry in next_doc.get("exceptions", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            continue
        prev = prev_by_id.get(entry["id"])
        if prev is None:
            continue
        if prev.get("status") == "expired" and entry.get("status") in {"active", "planned"}:
            result.error(
                "expired_reactivation",
                "expired exception reactivated without a new exception id",
                entry["id"],
            )


def build_health_report(
    doc: dict[str, Any],
    *,
    now: datetime | None = None,
    alert_hours: int = DEFAULT_ALERT_HOURS,
    validation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build an allowlisted operator report with no free-prose inventory fields."""
    now = now or datetime.now(timezone.utc)
    rows: list[dict[str, Any]] = []
    for entry in doc.get("exceptions", []):
        if not isinstance(entry, dict):
            continue
        expires_at = entry.get("expires_at")
        clock_state = "unknown"
        safe_expires: str | None = None
        if isinstance(expires_at, str) and RFC3339_RE.fullmatch(expires_at):
            try:
                expiry = parse_rfc3339(expires_at)
            except ValueError:
                clock_state = "invalid"
            else:
                safe_expires = expires_at
                if expiry <= now:
                    clock_state = "past_due"
                elif expiry <= now + timedelta(hours=alert_hours):
                    clock_state = "expiring_soon"
                else:
                    clock_state = "outside_alert_window"
        elif expires_at is None:
            clock_state = "unbounded"
        else:
            clock_state = "invalid"

        status = entry.get("status")
        component = entry.get("component")
        exc_id = entry.get("id")
        issue = entry.get("issue")
        row = {
            "id": exc_id if isinstance(exc_id, str) and ID_RE.fullmatch(exc_id) else "[INVALID]",
            "status": status if status in STATUSES else "[INVALID]",
            "component": component if component in COMPONENTS else "[INVALID]",
            "issue": issue if isinstance(issue, str) and ISSUE_RE.fullmatch(issue) else "[INVALID]",
            "expires_at": safe_expires,
            "clock_state": clock_state,
            "blocks_stable_promotion": entry.get("blocks_stable_promotion")
            if isinstance(entry.get("blocks_stable_promotion"), bool)
            else None,
        }
        assert set(row) == REPORT_ROW_KEYS
        rows.append(row)
    by_status: dict[str, list[str]] = {status: [] for status in sorted(STATUSES)}
    for row in rows:
        status = row.get("status")
        if status in by_status and isinstance(row.get("id"), str) and row["id"] != "[INVALID]":
            by_status[status].append(row["id"])
    env = doc.get("environment")
    updated = doc.get("updated_at")
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "environment": env if env == ENVIRONMENT else "[INVALID]",
        "register_updated_at": updated
        if isinstance(updated, str) and RFC3339_RE.fullmatch(updated)
        else "[INVALID]",
        "alert_hours": alert_hours,
        "counts": {status: len(ids) for status, ids in by_status.items()},
        "active_or_blocking": [
            row
            for row in rows
            if row.get("status") in {"active", "expired"}
            or row.get("blocks_stable_promotion") is True
        ],
        "exceptions": rows,
        "field_set": "allowlisted-v1",
        "note": (
            "Allowlisted operator inventory for registered rows only "
            "(id/status/component/issue/expires_at/clock_state/"
            "blocks_stable_promotion). Owner and free-prose policy fields are "
            "omitted by construction. Does not prove Pearl has no unregistered "
            "exceptions."
        ),
    }
    if validation is not None:
        report["validation"] = {
            "errors": [redact_secrets(str(item)) for item in validation.get("errors", [])],
            "warnings": [
                redact_secrets(str(item)) for item in validation.get("warnings", [])
            ],
            "ok": bool(validation.get("ok")),
        }
    # Residual scan uses a broader independent detector over the closed payload.
    probe = {key: value for key, value in report.items() if key != "secrets_redacted"}
    secrets_clean = not contains_residual_secret(json.dumps(probe, sort_keys=True))
    report["secrets_redacted"] = secrets_clean
    return report


def promote_warns_to_errors(result: ValidationResult, codes: Iterable[str]) -> ValidationResult:
    promote = set(codes)
    upgraded = ValidationResult()
    for finding in result.findings:
        if finding.severity == "warn" and finding.code in promote:
            upgraded.error(finding.code, finding.message, finding.exception_id)
        elif finding.severity == "error":
            upgraded.error(finding.code, finding.message, finding.exception_id)
        else:
            upgraded.warn(finding.code, finding.message, finding.exception_id)
    return upgraded


def apply_gate_policy(result: ValidationResult, mode: str, enforce: bool) -> ValidationResult:
    """Apply deploy/promote policy on top of structural validation findings."""
    if mode == "validate" and not enforce:
        return result
    promote_codes = {
        "status_expired",
        "unbounded_active",
        "expiry_soon",
        "blocks_stable_promotion",
    }
    if mode == "promote" or enforce:
        return promote_warns_to_errors(result, promote_codes)
    return result


def enforcement_enabled(cli_flag: bool | None = None) -> bool:
    if cli_flag is True:
        return True
    if cli_flag is False:
        return False
    return os.environ.get("MACPROVIDER_EXCEPTION_ENFORCEMENT", "0") == "1"


def _load_pair(args: argparse.Namespace) -> tuple[Path, dict[str, Any], dict[str, Any]]:
    root = Path(args.root) if args.root else repo_root_from_here()
    register_path = Path(args.register) if args.register else default_register_path(root)
    tombstone_path = Path(args.tombstones) if args.tombstones else default_tombstone_path(root)
    return root, load_json(register_path), load_json(tombstone_path)


def cmd_validate(args: argparse.Namespace) -> int:
    _root, doc, tombstones = _load_pair(args)
    now = parse_rfc3339(args.now) if args.now else datetime.now(timezone.utc)
    base = load_json(Path(args.base_tombstones)) if args.base_tombstones else None
    previous = load_json(Path(args.previous_register)) if args.previous_register else None
    result = validate_register(
        doc,
        now=now,
        tombstones=tombstones,
        alert_hours=args.alert_hours,
        previous_doc=previous,
        base_tombstones=base,
    )
    for finding in result.findings:
        print(finding.format(), file=sys.stderr if finding.severity == "error" else sys.stdout)
    if result.errors:
        print(f"production-exceptions: FAIL ({len(result.errors)} error(s))", file=sys.stderr)
        return 1
    print(
        f"production-exceptions: OK ({len(doc.get('exceptions', []))} rows, "
        f"{len(result.warnings)} warning(s))"
    )
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    _root, doc, tombstones = _load_pair(args)
    now = parse_rfc3339(args.now) if args.now else datetime.now(timezone.utc)
    result = validate_register(doc, now=now, tombstones=tombstones, alert_hours=args.alert_hours)
    report = build_health_report(
        doc,
        now=now,
        alert_hours=args.alert_hours,
        validation={
            "errors": [f.format() for f in result.errors],
            "warnings": [f.format() for f in result.warnings],
            "ok": not result.errors,
        },
    )
    if not report["secrets_redacted"]:
        print(
            "ERROR secrets_present <report>: refusing to emit secret-bearing report",
            file=sys.stderr,
        )
        return 1
    if result.errors:
        print(
            f"production-exceptions report: FAIL ({len(result.errors)} validation error(s)); "
            "not writing operator report",
            file=sys.stderr,
        )
        for finding in result.errors:
            print(finding.format(), file=sys.stderr)
        return 1
    text = json.dumps(report, indent=2, sort_keys=False) + "\n"
    if contains_residual_secret(text):
        print(
            "ERROR secrets_present <report>: residual secret-like material in serialized report",
            file=sys.stderr,
        )
        return 1
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        sys.stdout.write(text)
    return 0


def cmd_gate(args: argparse.Namespace) -> int:
    _root, doc, tombstones = _load_pair(args)
    now = parse_rfc3339(args.now) if args.now else datetime.now(timezone.utc)
    if args.enforce and args.no_enforce:
        print("cannot combine --enforce and --no-enforce", file=sys.stderr)
        return 2
    if args.no_enforce:
        enforce = False
    elif args.enforce:
        enforce = True
    else:
        enforce = enforcement_enabled()
    base = load_json(Path(args.base_tombstones)) if args.base_tombstones else None
    previous = load_json(Path(args.previous_register)) if args.previous_register else None
    result = validate_register(
        doc,
        now=now,
        tombstones=tombstones,
        alert_hours=args.alert_hours,
        previous_doc=previous,
        base_tombstones=base,
    )
    result = apply_gate_policy(result, args.mode, enforce)
    for finding in result.findings:
        stream = sys.stderr if finding.severity == "error" else sys.stdout
        print(finding.format(), file=stream)
    mode = args.mode
    if result.errors:
        print(
            f"production-exceptions gate[{mode}]: FAIL "
            f"(enforce={int(enforce or mode == 'promote')}, errors={len(result.errors)})",
            file=sys.stderr,
        )
        return 1
    print(
        f"production-exceptions gate[{mode}]: OK "
        f"(enforce={int(enforce or mode == 'promote')}, warnings={len(result.warnings)})"
    )
    return 0


def cmd_sync_check(args: argparse.Namespace) -> int:
    """Compare previous vs next register (or stale sync) for resurrection."""
    root = Path(args.root) if args.root else repo_root_from_here()
    current = load_json(Path(args.current))
    stale = load_json(Path(args.stale))
    now = parse_rfc3339(args.now) if args.now else datetime.now(timezone.utc)
    tombstones = load_json(
        Path(args.tombstones) if args.tombstones else default_tombstone_path(root)
    )
    result = simulate_config_sync_restore(current, stale, tombstones, now=now)
    for finding in result.findings:
        print(finding.format(), file=sys.stderr if finding.severity == "error" else sys.stdout)
    if result.errors:
        print(
            f"production-exceptions sync-check: FAIL ({len(result.errors)} error(s))",
            file=sys.stderr,
        )
        return 1
    print("production-exceptions sync-check: OK (no resurrection)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate, report, and gate the #615 production exception register."
    )
    parser.add_argument("--root", help="Repository root (default: inferred from script path)")
    parser.add_argument("--register", help="Path to production-exceptions.json")
    parser.add_argument("--tombstones", help="Path to removed-exception-tombstones.json")
    parser.add_argument(
        "--base-tombstones",
        help="Trusted previous tombstone ledger; deletions vs this base hard-fail",
    )
    parser.add_argument(
        "--previous-register",
        help="Previous register for anti-resurrection and expiry self-extension checks",
    )
    parser.add_argument("--now", help="RFC3339Z clock override for deterministic tests")
    parser.add_argument(
        "--alert-hours",
        type=int,
        default=DEFAULT_ALERT_HOURS,
        help=f"Approaching-expiry alert window (default {DEFAULT_ALERT_HOURS})",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_validate = sub.add_parser("validate", help="Structural + policy validation")
    p_validate.set_defaults(func=cmd_validate)

    p_report = sub.add_parser("report", help="Operator health/report JSON (no secrets)")
    p_report.add_argument("--output", "-o", help="Write report JSON to this path")
    p_report.set_defaults(func=cmd_report)

    p_gate = sub.add_parser("gate", help="Deploy or stable-promotion gate")
    p_gate.add_argument(
        "--mode",
        choices=("deploy", "promote", "validate"),
        default="deploy",
        help="deploy=default-safe; promote=fail-closed on expired/unbounded/blocking",
    )
    p_gate.add_argument(
        "--enforce",
        action="store_true",
        help="Fail closed like promote (or set MACPROVIDER_EXCEPTION_ENFORCEMENT=1)",
    )
    p_gate.add_argument(
        "--no-enforce",
        action="store_true",
        help="Force default-safe warnings even if the env var is set",
    )
    p_gate.set_defaults(func=cmd_gate)

    p_sync = sub.add_parser(
        "sync-check",
        help="Fail if stale authoritative sync would resurrect tombstoned/removed IDs",
    )
    p_sync.add_argument(
        "--current",
        required=True,
        help="Current register JSON (post-removal truth)",
    )
    p_sync.add_argument(
        "--stale",
        required=True,
        help="Stale authoritative register/export that sync might restore",
    )
    # SUPPRESS so a parent-level --tombstones is not overwritten by a missing
    # subparser value (argparse otherwise resets it to None).
    p_sync.add_argument(
        "--tombstones",
        default=argparse.SUPPRESS,
        help="Path to removed-exception-tombstones.json",
    )
    p_sync.set_defaults(func=cmd_sync_check)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
