#!/usr/bin/env python3
"""#615 production exception register loader, validator, report, and gates.

Dependency-free (stdlib only). Validates ops/exceptions/production-exceptions.json
against the committed schema's structural rules, enforces unique IDs / ownership /
expiry fail-closed behavior, emits an operator report without secrets, and gates
deploy / stable-promotion when configured.

Default-safe deploy behavior (MACPROVIDER_EXCEPTION_ENFORCEMENT unset/0):
  - Hard-fail: malformed register, duplicate IDs, ownerless rows, scope/environment
    mismatch, active rows past expires_at, resurrection of tombstoned IDs.
  - Warn only: status=expired rows, active rows with expires_at=null,
    approaching-expiry alerts.

Enforcement (MACPROVIDER_EXCEPTION_ENFORCEMENT=1) or --mode=promote:
  - All hard-fails above, plus status=expired, active null-expiry, and
    approaching-expiry (within alert window) become hard-fails.
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
OWNERLESS = frozenset(
    {
        "",
        "tbd",
        "todo",
        "unknown",
        "none",
        "n/a",
        "na",
        "unowned",
        "owner",
        "???",
    }
)
SECRET_RE = re.compile(
    r"(?i)(bearer\s+[a-z0-9._\-]+|sk-[a-z0-9]{10,}|ghp_[a-z0-9]{20,}|"
    r"xox[baprs]-[a-z0-9-]{10,}|-----BEGIN [A-Z ]+PRIVATE KEY-----|"
    r"password\s*[:=]\s*\S+|token\s*[:=]\s*\S+)"
)
REQUIRED_EXCEPTION_FIELDS = (
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
)
DEFAULT_ALERT_HOURS = 72


@dataclass
class Finding:
    severity: str  # error | warn
    code: str
    message: str
    exception_id: str | None = None

    def format(self) -> str:
        loc = self.exception_id or "<register>"
        return f"{self.severity.upper()} {self.code} {loc}: {self.message}"


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


def repo_root_from_here() -> Path:
    return Path(__file__).resolve().parent.parent


def default_register_path(root: Path | None = None) -> Path:
    return (root or repo_root_from_here()) / "ops/exceptions/production-exceptions.json"


def default_tombstone_path(root: Path | None = None) -> Path:
    return (root or repo_root_from_here()) / "ops/exceptions/removed-exception-tombstones.json"


def default_schema_path(root: Path | None = None) -> Path:
    return (root or repo_root_from_here()) / "ops/exceptions/production-exceptions.schema.json"


def parse_rfc3339(value: str) -> datetime:
    if not RFC3339_RE.fullmatch(value):
        raise ValueError(f"not RFC3339Z: {value!r}")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def redact_secrets(text: str) -> str:
    return SECRET_RE.sub("[REDACTED]", text)


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
    return bool(cleaned) and cleaned.lower() not in OWNERLESS


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
    # Scope widening signals that are never acceptable on active/planned rows.
    if entry.get("status") in {"active", "planned"}:
        lowered = scope.lower()
        if "all providers" in lowered and "must not widen" not in lowered:
            return "scope appears globally widened without an explicit 'must not widen' bound"
        if "arbitrary" in lowered:
            prohibited = (
                "must not" in lowered
                or "must not widen" in lowered
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
) -> ValidationResult:
    result = ValidationResult()
    now = now or datetime.now(timezone.utc)
    if not isinstance(doc, dict):
        result.error("register_type", "register root must be an object")
        return result

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
    if not isinstance(updated_at, str) or not RFC3339_RE.fullmatch(updated_at):
        result.error("updated_at", "updated_at must be RFC3339Z")
    if not isinstance(doc.get("updated_by"), str) or not doc.get("updated_by", "").strip():
        result.error("updated_by", "updated_by must be a non-empty string")

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
            result.error(
                "environment",
                f"environment must be {ENVIRONMENT!r}",
                exc_id,
            )
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
        if not isinstance(entry.get("evidence"), list):
            result.error("evidence", "evidence must be an array", exc_id)

        created_at = entry.get("created_at")
        if created_at is not None:
            if not isinstance(created_at, str) or not RFC3339_RE.fullmatch(created_at):
                result.error("created_at", "created_at must be RFC3339Z or null", exc_id)

        expires_at = entry.get("expires_at")
        expiry_unknown = entry.get("expiry_unknown_reason")
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
            if not isinstance(expires_at, str) or not RFC3339_RE.fullmatch(expires_at):
                result.error("expires_at", "expires_at must be RFC3339Z or null", exc_id)
            else:
                try:
                    expiry = parse_rfc3339(expires_at)
                except ValueError as exc:
                    result.error("expires_at", str(exc), exc_id)
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
            oq_id = item.get("id") if isinstance(item.get("id"), str) else f"open_questions[{index}]"
            for key in ("id", "question", "owner", "status", "evidence_target"):
                if key not in item:
                    result.error("open_question_fields", f"missing {key}", oq_id)
            if isinstance(item.get("id"), str):
                if not OQ_ID_RE.fullmatch(item["id"]):
                    result.error("open_question_id", "invalid open-question id", oq_id)
                else:
                    oq_ids.append(item["id"])
            if not _owner_ok(item.get("owner")):
                result.error("ownerless", "open question owner is missing or placeholder", oq_id)
            if item.get("status") not in {"pending", "answered"}:
                result.error("open_question_status", f"invalid status {item.get('status')!r}", oq_id)
        oq_dupes = sorted({item for item in oq_ids if oq_ids.count(item) > 1})
        if oq_dupes:
            result.error("duplicate_oq_ids", f"duplicate open_question ids: {oq_dupes}")

    tombstone_ids = set()
    if tombstones is not None:
        tombstone_ids = validate_tombstones(tombstones, result)

    for entry in exceptions:
        if not isinstance(entry, dict):
            continue
        exc_id = entry.get("id")
        if not isinstance(exc_id, str):
            continue
        if exc_id in tombstone_ids and entry.get("status") != "removed":
            result.error(
                "resurrection",
                "tombstoned exception id reappears with non-removed status",
                exc_id,
            )

    if previous_doc is not None:
        check_anti_resurrection(previous_doc, doc, tombstone_ids, result)

    return result


def validate_tombstones(doc: dict[str, Any], result: ValidationResult | None = None) -> set[str]:
    result = result or ValidationResult()
    ids: set[str] = set()
    if not isinstance(doc, dict):
        result.error("tombstone_type", "tombstone root must be an object")
        return ids
    if doc.get("schema_version") != TOMBSTONE_SCHEMA_VERSION:
        result.error(
            "tombstone_schema",
            f"tombstone schema_version must be {TOMBSTONE_SCHEMA_VERSION!r}",
        )
    if doc.get("environment") != ENVIRONMENT:
        result.error("tombstone_environment", f"environment must be {ENVIRONMENT!r}")
    rows = doc.get("tombstones")
    if not isinstance(rows, list):
        result.error("tombstones", "tombstones must be an array")
        return ids
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            result.error("tombstone_entry", f"tombstones[{index}] must be an object")
            continue
        exc_id = row.get("id")
        if not isinstance(exc_id, str) or not ID_RE.fullmatch(exc_id):
            result.error("tombstone_id", f"tombstones[{index}].id is invalid")
            continue
        if exc_id in ids:
            result.error("tombstone_duplicate", f"duplicate tombstone id {exc_id}")
        ids.add(exc_id)
        removed_at = row.get("removed_at")
        if not isinstance(removed_at, str) or not RFC3339_RE.fullmatch(removed_at):
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
    """Fail if a removed/tombstoned exception returns as active/planned/expired."""
    prev_by_id = {
        entry["id"]: entry
        for entry in previous_doc.get("exceptions", [])
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    for entry in next_doc.get("exceptions", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            continue
        exc_id = entry["id"]
        prev = prev_by_id.get(exc_id)
        resurrecting = entry.get("status") in {"active", "planned", "expired"}
        if not resurrecting:
            continue
        if exc_id in tombstone_ids:
            result.error(
                "resurrection",
                "config/register sync would restore a tombstoned exception id",
                exc_id,
            )
        if prev is not None and prev.get("status") == "removed":
            result.error(
                "resurrection",
                "removed exception id was restored from a non-removed status",
                exc_id,
            )


def simulate_config_sync_restore(
    current_doc: dict[str, Any],
    stale_authoritative_doc: dict[str, Any],
    tombstones: dict[str, Any],
) -> ValidationResult:
    """Model a sync/rollback that re-applies stale authoritative exception rows."""
    merged = deepcopy(current_doc)
    by_id = {
        entry["id"]: entry
        for entry in merged.get("exceptions", [])
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    for entry in stale_authoritative_doc.get("exceptions", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            continue
        # Stale sync restores the old row verbatim.
        by_id[entry["id"]] = deepcopy(entry)
    merged["exceptions"] = list(by_id.values())
    tombstone_ids = validate_tombstones(tombstones)
    result = ValidationResult()
    check_anti_resurrection(current_doc, merged, tombstone_ids, result)
    # Also treat tombstone membership as authoritative even if previous lacked removed.
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
    return result


def build_health_report(
    doc: dict[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    rows: list[dict[str, Any]] = []
    for entry in doc.get("exceptions", []):
        if not isinstance(entry, dict):
            continue
        expires_at = entry.get("expires_at")
        clock_state = "unknown"
        if isinstance(expires_at, str) and RFC3339_RE.fullmatch(expires_at):
            expiry = parse_rfc3339(expires_at)
            if expiry <= now:
                clock_state = "past_due"
            elif expiry <= now + timedelta(hours=DEFAULT_ALERT_HOURS):
                clock_state = "expiring_soon"
            else:
                clock_state = "within_window"
        elif expires_at is None:
            clock_state = "unbounded"
        rows.append(
            {
                "id": entry.get("id"),
                "status": entry.get("status"),
                "component": entry.get("component"),
                "owner": entry.get("owner"),
                "issue": entry.get("issue"),
                "expires_at": expires_at,
                "clock_state": clock_state,
                "blocks_stable_promotion": entry.get("blocks_stable_promotion"),
                "scope": redact_secrets(str(entry.get("scope", ""))),
                "authority_surface": redact_secrets(str(entry.get("authority_surface", ""))),
                "policy_delta": redact_secrets(str(entry.get("policy_delta", ""))),
                "reason": redact_secrets(str(entry.get("reason", ""))),
            }
        )
    by_status: dict[str, list[str]] = {status: [] for status in sorted(STATUSES)}
    for row in rows:
        status = row.get("status")
        if status in by_status and isinstance(row.get("id"), str):
            by_status[status].append(row["id"])
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "environment": doc.get("environment"),
        "register_updated_at": doc.get("updated_at"),
        "counts": {status: len(ids) for status, ids in by_status.items()},
        "active_or_blocking": [
            row
            for row in rows
            if row.get("status") in {"active", "expired"}
            or row.get("blocks_stable_promotion") is True
        ],
        "exceptions": rows,
        "secrets_redacted": True,
        "note": (
            "Operator-visible exception inventory. No bearer tokens, HMAC secrets, "
            "referral codes, or private keys are included."
        ),
    }


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
        # Validate keeps structural errors; demote policy warnings stay warnings.
        return result
    promote_codes = {
        "status_expired",
        "unbounded_active",
        "expiry_soon",
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


def cmd_validate(args: argparse.Namespace) -> int:
    root = Path(args.root) if args.root else repo_root_from_here()
    doc = load_json(Path(args.register) if args.register else default_register_path(root))
    tombstones = load_json(
        Path(args.tombstones) if args.tombstones else default_tombstone_path(root)
    )
    now = parse_rfc3339(args.now) if args.now else datetime.now(timezone.utc)
    result = validate_register(
        doc,
        now=now,
        tombstones=tombstones,
        alert_hours=args.alert_hours,
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
    root = Path(args.root) if args.root else repo_root_from_here()
    doc = load_json(Path(args.register) if args.register else default_register_path(root))
    now = parse_rfc3339(args.now) if args.now else datetime.now(timezone.utc)
    # Still validate so a broken register cannot look healthy.
    tombstones = load_json(
        Path(args.tombstones) if args.tombstones else default_tombstone_path(root)
    )
    result = validate_register(doc, now=now, tombstones=tombstones, alert_hours=args.alert_hours)
    report = build_health_report(doc, now=now)
    report["validation"] = {
        "errors": [f.format() for f in result.errors],
        "warnings": [f.format() for f in result.warnings],
        "ok": not result.errors,
    }
    text = json.dumps(report, indent=2, sort_keys=False) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        sys.stdout.write(text)
    return 1 if result.errors else 0


def cmd_gate(args: argparse.Namespace) -> int:
    root = Path(args.root) if args.root else repo_root_from_here()
    doc = load_json(Path(args.register) if args.register else default_register_path(root))
    tombstones = load_json(
        Path(args.tombstones) if args.tombstones else default_tombstone_path(root)
    )
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
    result = validate_register(
        doc,
        now=now,
        tombstones=tombstones,
        alert_hours=args.alert_hours,
    )
    result = apply_gate_policy(result, args.mode, enforce)
    for finding in result.findings:
        stream = sys.stderr if finding.severity == "error" else sys.stdout
        print(finding.format(), file=stream)
    mode = args.mode
    if result.errors:
        print(
            f"production-exceptions gate[{mode}]: FAIL "
            f"(enforce={int(enforce)}, errors={len(result.errors)})",
            file=sys.stderr,
        )
        return 1
    print(
        f"production-exceptions gate[{mode}]: OK "
        f"(enforce={int(enforce)}, warnings={len(result.warnings)})"
    )
    return 0


def cmd_sync_check(args: argparse.Namespace) -> int:
    """Compare previous vs next register (or stale sync) for resurrection."""
    root = Path(args.root) if args.root else repo_root_from_here()
    current = load_json(Path(args.current))
    stale = load_json(Path(args.stale))
    tombstones = load_json(
        Path(args.tombstones) if args.tombstones else default_tombstone_path(root)
    )
    result = simulate_config_sync_restore(current, stale, tombstones)
    for finding in result.findings:
        print(finding.format(), file=sys.stderr if finding.severity == "error" else sys.stdout)
    if result.errors:
        print(
            f"production-exceptions sync-check: FAIL ({len(result.errors)} resurrection error(s))",
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
        help="deploy=default-safe; promote=fail-closed on expired/unbounded",
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
    p_sync.set_defaults(func=cmd_sync_check)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
