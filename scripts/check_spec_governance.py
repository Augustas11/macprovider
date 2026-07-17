#!/usr/bin/env python3
"""Validate the SPEC authority and conformance governance foundation.

The checker intentionally uses only the Python standard library. JSON Schema
files document the public manifest contract; this module performs equivalent
fail-closed validation with repository-aware checks and actionable errors.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any


SPEC_ID_RE = re.compile(r"^SPEC-\d{3}$")
REQUIREMENT_ID_RE = re.compile(r"^SPEC-(\d{3})-R\d{3}$")
REQUIREMENT_DEFINITION_RE = re.compile(
    r"^\*\*(SPEC-\d{3}-R\d{3})\s+[—-]", re.MULTILINE
)
REQUIREMENT_REFERENCE_RE = re.compile(r"\bSPEC-\d{3}-R\d{3}\b")
SPEC_REFERENCE_RE = re.compile(r"\bSPEC-\d{3}\b")
TITLE_RE = re.compile(r"^#\s+(SPEC-\d{3})\s*[—–:-]\s*(.+)$")
VERSION_RE = re.compile(r"^Version:\s*\S+", re.IGNORECASE)
STATUS_VERSION_RE = re.compile(r"^Status:.*\bv?\d+\.\d+", re.IGNORECASE)
DOMAIN_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ISSUE_RE = re.compile(r"^https://github\.com/Augustas11/macprovider/issues/\d+$")
OWNER_RE = re.compile(r"^@[A-Za-z0-9-]+$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
FINGERPRINT_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
ARTIFACT_RE = re.compile(
    r"^(?:commit:[0-9a-f]{40}|sha256:[0-9a-f]{64})$"
)
JOURNEY_RE = re.compile(r"^JOURNEY-[A-Z0-9]+(?:-[A-Z0-9]+)*$")
NORMATIVE_KEYWORD_RE = re.compile(r"\b(?:MUST(?:\s+NOT)?|SHOULD)\b")
MARKDOWN_LINK_RE = re.compile(r"\]\(([^)]+)\)")

AUTHORITY_SCHEMA_PATH = "../schemas/spec-authority-v1.schema.json"
CONFORMANCE_SCHEMA_PATH = "../schemas/spec-conformance-v1.schema.json"
TRACKED_SCHEMA_SHA256 = {
    "spec-authority-v1.schema.json": "1a56337905558224f12c789a86edcbf5e91fba7791b337949593c5f0678b51a7",
    "spec-conformance-v1.schema.json": "81769b5397dd8b7b831329fd80f6f924884ebebc154a1605d91b9c8857083930",
}
SENSITIVE_PHYSICAL_DOMAINS = {
    "provider-wire-protocol",
    "provider-onboarding-identity",
    "tier2-trust-evidence",
    "model-catalog-identity",
    "operator-pushed-warm-swap",
    "coordinator-demand-pull-model-swap",
    "provider-autoupdate",
    "installer-autotune-policy",
    "native-app-lifecycle",
    "browserless-onboarding",
    "provider-wallet-proof",
    "hardware-evidence-admission",
    "hardware-evidence-verifier",
}

LIFECYCLE_STATES = {
    "draft",
    "normative",
    "implemented-unverified",
    "physically-verified",
    "deprecated",
}
IMPLEMENTATION_STATES = {
    "pending-reconciliation",
    "partial",
    "implemented",
    "not-applicable",
}
PRODUCTION_STATES = {
    "pending-verification",
    "not-deployed",
    "partially-deployed",
    "physically-verified",
    "not-applicable",
}
AUTHORITY_STATES = {"declared", "pending-reconciliation", "deprecated"}
CONFORMANCE_STATES = {
    "pending",
    "blocked",
    "conformant",
    "nonconformant",
    "not-applicable",
}
VERDICTS = {
    "CODE_BUG",
    "SPEC_BUG",
    "DECISION_REQUIRED",
    "DUPLICATE_AUTHORITY",
    "UNKNOWN",
}
RAW_HTML_BLOCK_TAGS = (
    "address|article|aside|base|basefont|blockquote|body|caption|center|col|"
    "colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|"
    "footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|"
    "li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|"
    "search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul"
)
RAW_HTML_BLOCK_TAG_RE = re.compile(
    rf" {{0,3}}</?(?:{RAW_HTML_BLOCK_TAGS})(?:\s|/?>|$)",
    re.IGNORECASE,
)
RAW_HTML_COMPLETE_TAG_RE = re.compile(
    r" {0,3}</?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?/?>[ \t]*$",
)
BOOTSTRAP_BASELINE_COMMIT = "1df5f76c3fbde1b84619b717fcc28ef1e2c05bc3"
LIFECYCLE_TRANSITIONS = {
    "draft": {"draft", "normative", "deprecated"},
    "normative": {"normative", "implemented-unverified", "deprecated"},
    "implemented-unverified": {"implemented-unverified", "physically-verified", "deprecated"},
    "physically-verified": {"physically-verified", "deprecated"},
    "deprecated": {"deprecated"},
}


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)

    def error(self, location: str, message: str) -> None:
        self.errors.append(f"{location}: {message}")


class DuplicateJSONKeyError(ValueError):
    pass


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateJSONKeyError(key)
        value[key] = item
    return value


def _contract_markdown(text: str) -> str:
    """Return Markdown contract text without examples or HTML comments."""
    raw_lines = text.splitlines()
    lines: list[str] = []
    fence: tuple[str, int] | None = None
    code_span: int | None = None
    raw_html_end: re.Pattern[str] | None = None
    raw_html_until_blank = False
    in_comment = False
    for line_index, raw_line in enumerate(raw_lines):
        if fence is not None:
            delimiter, minimum_length = fence
            closing = re.fullmatch(r" {0,3}([`~]+)[ \t]*", raw_line)
            if (
                closing is not None
                and closing.group(1)[0] == delimiter
                and len(closing.group(1)) >= minimum_length
                and set(closing.group(1)) == {delimiter}
            ):
                fence = None
            lines.append("")
            continue

        if raw_html_end is not None:
            if raw_html_end.search(raw_line):
                raw_html_end = None
            lines.append("")
            continue
        if raw_html_until_blank:
            if not raw_line.strip():
                raw_html_until_blank = False
            lines.append("")
            continue

        if code_span is None and not in_comment:
            raw_html_opening = re.match(
                r" {0,3}<(pre|script|style|textarea)(?:\s|>|$)",
                raw_line,
                re.IGNORECASE,
            )
            if raw_html_opening is not None:
                tag = raw_html_opening.group(1)
                if re.search(rf"</{tag}\s*>", raw_line, re.IGNORECASE) is None:
                    raw_html_end = re.compile(rf"</{tag}\s*>", re.IGNORECASE)
                lines.append("")
                continue
            raw_html_special = (
                (r" {0,3}<\?", re.compile(r"\?>")),
                (r" {0,3}<!\[CDATA\[", re.compile(r"\]\]>")),
                (r" {0,3}<![A-Z]", re.compile(r">")),
            )
            matched_special = False
            for opening_pattern, closing_pattern in raw_html_special:
                if re.match(opening_pattern, raw_line) is None:
                    continue
                if closing_pattern.search(raw_line) is None:
                    raw_html_end = closing_pattern
                matched_special = True
                break
            if matched_special:
                lines.append("")
                continue
            if (
                RAW_HTML_BLOCK_TAG_RE.match(raw_line) is not None
                or RAW_HTML_COMPLETE_TAG_RE.fullmatch(raw_line) is not None
            ):
                raw_html_until_blank = True
                lines.append("")
                continue
            opening = re.fullmatch(r" {0,3}(`{3,}|~{3,})(.*)", raw_line)
            if opening is not None:
                marker, info = opening.groups()
                if marker[0] == "~" or "`" not in info:
                    fence = (marker[0], len(marker))
                    lines.append("")
                    continue

        visible: list[str] = []
        cursor = 0
        while cursor < len(raw_line):
            if code_span is not None:
                if raw_line[cursor] != "`":
                    visible.append(raw_line[cursor])
                    cursor += 1
                    continue
                end = cursor
                while end < len(raw_line) and raw_line[end] == "`":
                    end += 1
                visible.append(raw_line[cursor:end])
                if end - cursor == code_span:
                    code_span = None
                cursor = end
                continue
            if in_comment:
                end = raw_line.find("-->", cursor)
                if end == -1:
                    cursor = len(raw_line)
                    break
                in_comment = False
                cursor = end + 3
                continue
            if (
                raw_line[cursor] == "\\"
                and cursor + 1 < len(raw_line)
                and raw_line[cursor + 1] in r"""!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"""
            ):
                visible.append(raw_line[cursor:cursor + 2])
                cursor += 2
                continue
            if raw_line[cursor] == "`":
                end = cursor
                while end < len(raw_line) and raw_line[end] == "`":
                    end += 1
                run_length = end - cursor
                if _has_code_span_closer(raw_lines, line_index, end, run_length):
                    code_span = run_length
                visible.append(raw_line[cursor:end])
                cursor = end
                continue
            if raw_line.startswith("<!--", cursor):
                in_comment = True
                cursor += 4
                continue
            visible.append(raw_line[cursor])
            cursor += 1
        line = "".join(visible)
        lines.append(line)
    return "\n".join(lines)


def _has_code_span_closer(
    lines: list[str],
    line_index: int,
    cursor: int,
    run_length: int,
) -> bool:
    """Return whether an exact CommonMark code-span closer exists in this paragraph."""
    for candidate_index in range(line_index, len(lines)):
        candidate = lines[candidate_index]
        if candidate_index != line_index:
            if not candidate.strip():
                return False
            cursor = 0
        while cursor < len(candidate):
            start = candidate.find("`", cursor)
            if start == -1:
                break
            end = start
            while end < len(candidate) and candidate[end] == "`":
                end += 1
            if end - start == run_length:
                return True
            cursor = end
    return False


def _legacy_normative_lines(text: str) -> list[str]:
    """Return frozen, unnumbered normative lines from contract Markdown."""
    lines: list[str] = []
    for raw_line in _contract_markdown(text).splitlines():
        stripped = raw_line.strip()
        if not NORMATIVE_KEYWORD_RE.search(stripped):
            continue
        if REQUIREMENT_DEFINITION_RE.match(stripped):
            continue
        lines.append(" ".join(stripped.split()))
    return lines


def legacy_requirement_fingerprint(text: str) -> tuple[str, int]:
    lines = _legacy_normative_lines(text)
    digest = hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()
    return f"sha256:{digest}", len(lines)


def _mapping_parts(value: str) -> tuple[str, str | None]:
    if "::" in value:
        return tuple(value.split("::", 1))
    if ":" in value:
        return tuple(value.split(":", 1))
    return value, None


def _validate_mapping_paths(
    values: list[str], field_name: str, location: str, root: Path,
    result: ValidationResult,
) -> None:
    for value in values:
        relative, selector = _mapping_parts(value)
        path = (root / relative).resolve()
        try:
            normalized = path.relative_to(root).as_posix()
        except ValueError:
            result.error(location, f"{field_name} mapping escapes repository: {value!r}")
            continue
        if not path.is_file():
            result.error(location, f"{field_name} mapping path does not exist: {relative!r}")
            continue
        lowered = normalized.lower()
        if field_name == "implementation" and lowered.startswith(("specs/", "docs/", "audits/", "schemas/", "scripts/tests/", "tests/", "test/")):
            result.error(location, f"implementation mapping must target executable source, not {relative!r}")
        if field_name == "test" and "test" not in Path(relative).name.lower() and "/tests/" not in f"/{lowered}":
            result.error(location, f"test mapping must target a test file: {relative!r}")
        if not selector:
            result.error(location, f"{field_name} mapping requires a symbol or test selector: {value!r}")
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            result.error(location, f"cannot inspect {field_name} mapping {relative!r}: {exc}")
            continue
        if selector not in content:
            result.error(location, f"{field_name} mapping selector {selector!r} was not found in {relative!r}")


def _commit_covers_mappings(root: Path, commit: str, mappings: list[str]) -> bool:
    for mapping in mappings:
        relative, selector = _mapping_parts(mapping)
        if not selector:
            return False
        path = (root / relative).resolve()
        try:
            relative = path.relative_to(root).as_posix()
        except ValueError:
            return False
        shown = subprocess.run(
            ["git", "show", f"{commit}:{relative}"],
            cwd=root, capture_output=True, text=True,
        )
        if shown.returncode or selector not in shown.stdout:
            return False
        unchanged = subprocess.run(
            ["git", "diff", "--quiet", commit, "--", relative],
            cwd=root, capture_output=True, text=True,
        )
        if unchanged.returncode:
            return False
    return True


def _is_physical_evidence_path(root: Path, source: str) -> bool:
    path = (root / source).resolve()
    try:
        normalized = path.relative_to(root).as_posix()
    except ValueError:
        return False
    return normalized.startswith("journeys/evidence/")


def _load_json(path: Path, result: ValidationResult) -> Any | None:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_unique_json_object,
        )
    except FileNotFoundError:
        result.error(str(path), "required manifest does not exist")
    except DuplicateJSONKeyError as exc:
        result.error(str(path), f"duplicate JSON object key {str(exc)!r}")
    except json.JSONDecodeError as exc:
        result.error(str(path), f"invalid JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}")
    except UnicodeDecodeError as exc:
        result.error(str(path), f"invalid UTF-8: {exc}")
    except OSError as exc:
        result.error(str(path), f"cannot read manifest: {exc}")
    return None


def _expect_object(value: Any, location: str, result: ValidationResult) -> bool:
    if not isinstance(value, dict):
        result.error(location, f"expected object, got {type(value).__name__}")
        return False
    return True


def _expect_keys(
    value: dict[str, Any], required: set[str], allowed: set[str], location: str,
    result: ValidationResult,
) -> None:
    for key in sorted(required - value.keys()):
        result.error(location, f"missing required field '{key}'")
    for key in sorted(value.keys() - allowed):
        result.error(location, f"unexpected field '{key}'")


def _expect_string(
    value: dict[str, Any], key: str, location: str, result: ValidationResult,
    pattern: re.Pattern[str] | None = None,
) -> str | None:
    item = value.get(key)
    if not isinstance(item, str) or not item:
        result.error(location, f"field '{key}' must be a non-empty string")
        return None
    if pattern and not pattern.fullmatch(item):
        result.error(location, f"field '{key}' has invalid value {item!r}")
        return None
    return item


def _expect_string_list(
    value: dict[str, Any], key: str, location: str, result: ValidationResult,
) -> list[str]:
    item = value.get(key)
    if not isinstance(item, list):
        result.error(location, f"field '{key}' must be an array")
        return []
    strings: list[str] = []
    for index, entry in enumerate(item):
        if not isinstance(entry, str) or not entry:
            result.error(f"{location}.{key}[{index}]", "must be a non-empty string")
        else:
            strings.append(entry)
    if len(strings) != len(set(strings)):
        result.error(location, f"field '{key}' contains duplicate values")
    return strings


def _expect_date(value: Any, location: str, result: ValidationResult) -> date | None:
    if not isinstance(value, str):
        result.error(location, "must be an ISO-8601 date string")
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        result.error(location, f"invalid ISO-8601 date {value!r}")
        return None


def _validate_baseline(
    value: Any, location: str, result: ValidationResult, today: date,
) -> tuple[str | None, date | None]:
    if not _expect_object(value, location, result):
        return None, None
    _expect_keys(value, {"commit", "captured_at"}, {"commit", "captured_at"}, location, result)
    commit = _expect_string(value, "commit", location, result, COMMIT_RE)
    captured = _expect_date(value.get("captured_at"), f"{location}.captured_at", result)
    if captured and captured > today:
        result.error(f"{location}.captured_at", "baseline capture date is in the future")
    if commit and commit != BOOTSTRAP_BASELINE_COMMIT:
        result.error(location, f"commit must remain pinned to bootstrap baseline {BOOTSTRAP_BASELINE_COMMIT}")
    return commit, captured


def _validate_gap(value: Any, location: str, result: ValidationResult) -> None:
    if not _expect_object(value, location, result):
        return
    allowed = {"verdict", "owner", "issue", "rationale"}
    _expect_keys(value, {"verdict", "owner", "issue"}, allowed, location, result)
    verdict = _expect_string(value, "verdict", location, result)
    if verdict and verdict not in VERDICTS:
        result.error(location, f"invalid arbitration verdict {verdict!r}; allowed: {sorted(VERDICTS)}")
    _expect_string(value, "owner", location, result, OWNER_RE)
    _expect_string(value, "issue", location, result, ISSUE_RE)
    if "rationale" in value:
        _expect_string(value, "rationale", location, result)


def _validate_evidence_list(
    value: Any, location: str, result: ValidationResult, today: date, root: Path,
) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        result.error(location, "must be an array")
        return []
    valid: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        evidence_loc = f"{location}[{index}]"
        if not _expect_object(item, evidence_loc, result):
            continue
        required_evidence = {"artifact", "source", "captured_at", "expires_at"}
        _expect_keys(item, required_evidence, required_evidence, evidence_loc, result)
        artifact = _expect_string(item, "artifact", evidence_loc, result)
        if artifact and not ARTIFACT_RE.fullmatch(artifact):
            result.error(evidence_loc, "artifact must be a reachable commit SHA or a recomputable sha256 digest")
        source = item.get("source")
        if artifact and artifact.startswith("commit:"):
            if source is not None:
                result.error(evidence_loc, "commit evidence source must be null")
            if (root / ".git").exists():
                commit = artifact.removeprefix("commit:")
                check = subprocess.run(
                    ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
                    cwd=root, capture_output=True, text=True,
                )
                if check.returncode:
                    result.error(evidence_loc, f"evidence commit {commit} is not reachable")
                else:
                    ancestor = subprocess.run(
                        ["git", "merge-base", "--is-ancestor", commit, "HEAD"],
                        cwd=root, capture_output=True, text=True,
                    )
                    if ancestor.returncode:
                        result.error(evidence_loc, f"evidence commit {commit} is not an ancestor of HEAD")
        elif artifact and artifact.startswith("sha256:"):
            if not isinstance(source, str) or not source:
                result.error(evidence_loc, "sha256 evidence requires a repository-relative source file")
            else:
                source_path = (root / source).resolve()
                try:
                    source_path.relative_to(root)
                except ValueError:
                    result.error(evidence_loc, f"evidence source escapes repository: {source!r}")
                else:
                    if not source_path.is_file():
                        result.error(evidence_loc, f"evidence source does not exist: {source!r}")
                    else:
                        digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
                        if artifact != f"sha256:{digest}":
                            result.error(evidence_loc, f"sha256 evidence does not match source {source!r}")
        elif source is not None:
            result.error(evidence_loc, "invalid evidence source")
        captured = _expect_date(item.get("captured_at"), f"{evidence_loc}.captured_at", result)
        expires = _expect_date(item.get("expires_at"), f"{evidence_loc}.expires_at", result)
        if captured and expires and expires < captured:
            result.error(evidence_loc, "expires_at precedes captured_at")
        if captured and captured > today:
            result.error(evidence_loc, "captured_at is in the future")
        if expires and expires < today:
            result.error(evidence_loc, f"evidence expired on {expires.isoformat()}")
        valid.append(item)
    return valid


def _validate_authority_schema(
    value: Any, result: ValidationResult, today: date,
) -> tuple[list[dict[str, Any]], tuple[str | None, date | None]]:
    location = "specs/AUTHORITY.json"
    if not _expect_object(value, location, result):
        return [], (None, None)
    required = {"$schema", "schema_version", "baseline", "domains"}
    _expect_keys(value, required, required, location, result)
    schema = _expect_string(value, "$schema", location, result)
    if schema and schema != AUTHORITY_SCHEMA_PATH:
        result.error(location, f"$schema must equal {AUTHORITY_SCHEMA_PATH!r}")
    version = _expect_string(value, "schema_version", location, result)
    if version and version != "spec-authority-v1":
        result.error(location, "schema_version must equal 'spec-authority-v1'")
    baseline = _validate_baseline(value.get("baseline"), f"{location}.baseline", result, today)
    domains = value.get("domains")
    if not isinstance(domains, list):
        result.error(location, "field 'domains' must be an array")
        return [], baseline
    valid: list[dict[str, Any]] = []
    for index, domain in enumerate(domains):
        loc = f"{location}.domains[{index}]"
        if not _expect_object(domain, loc, result):
            continue
        required_domain = {"id", "owner_spec", "consumers", "status", "owner", "issue"}
        _expect_keys(domain, required_domain, required_domain, loc, result)
        _expect_string(domain, "id", loc, result, DOMAIN_RE)
        _expect_string(domain, "owner_spec", loc, result, SPEC_ID_RE)
        consumers = _expect_string_list(domain, "consumers", loc, result)
        for consumer in consumers:
            if not SPEC_ID_RE.fullmatch(consumer):
                result.error(loc, f"consumer {consumer!r} is not a SPEC-NNN ID")
        status = _expect_string(domain, "status", loc, result)
        if status and status not in AUTHORITY_STATES:
            result.error(loc, f"invalid authority status {status!r}; allowed: {sorted(AUTHORITY_STATES)}")
        _expect_string(domain, "owner", loc, result, OWNER_RE)
        _expect_string(domain, "issue", loc, result, ISSUE_RE)
        valid.append(domain)
    return valid, baseline


def _validate_conformance_schema(
    value: Any, result: ValidationResult, today: date, root: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], tuple[str | None, date | None]]:
    location = "specs/CONFORMANCE.json"
    if not _expect_object(value, location, result):
        return [], [], (None, None)
    required = {"$schema", "schema_version", "baseline", "specs", "requirements"}
    _expect_keys(value, required, required, location, result)
    schema = _expect_string(value, "$schema", location, result)
    if schema and schema != CONFORMANCE_SCHEMA_PATH:
        result.error(location, f"$schema must equal {CONFORMANCE_SCHEMA_PATH!r}")
    version = _expect_string(value, "schema_version", location, result)
    if version and version != "spec-conformance-v1":
        result.error(location, "schema_version must equal 'spec-conformance-v1'")
    baseline = _validate_baseline(value.get("baseline"), f"{location}.baseline", result, today)

    spec_records = value.get("specs")
    if not isinstance(spec_records, list):
        result.error(location, "field 'specs' must be an array")
        spec_records = []
    valid_specs: list[dict[str, Any]] = []
    spec_required = {
        "spec_id", "title", "version", "path", "status", "owner",
        "authority_domains", "supersedes", "depends_on", "implementation_status",
        "production_status", "last_reconciled_commit", "last_reconciled_at",
        "evidence", "requirement_id_migration", "legacy_requirement_fingerprint",
        "legacy_requirement_count", "gap",
    }
    spec_allowed = spec_required | {"superseded_by", "deprecation_rationale"}
    for index, spec in enumerate(spec_records):
        loc = f"{location}.specs[{index}]"
        if not _expect_object(spec, loc, result):
            continue
        _expect_keys(spec, spec_required, spec_allowed, loc, result)
        _expect_string(spec, "spec_id", loc, result, SPEC_ID_RE)
        _expect_string(spec, "title", loc, result)
        _expect_string(spec, "version", loc, result)
        _expect_string(spec, "path", loc, result)
        status = _expect_string(spec, "status", loc, result)
        if status and status not in LIFECYCLE_STATES:
            result.error(loc, f"invalid lifecycle state {status!r}; allowed: {sorted(LIFECYCLE_STATES)}")
        _expect_string(spec, "owner", loc, result, OWNER_RE)
        _expect_string_list(spec, "authority_domains", loc, result)
        for field_name in ("supersedes", "depends_on", "superseded_by"):
            if field_name not in spec and field_name == "superseded_by":
                continue
            for referenced_spec in _expect_string_list(spec, field_name, loc, result):
                if not SPEC_ID_RE.fullmatch(referenced_spec):
                    result.error(loc, f"{field_name} contains invalid spec ID {referenced_spec!r}")
        implementation = _expect_string(spec, "implementation_status", loc, result)
        if implementation and implementation not in IMPLEMENTATION_STATES:
            result.error(loc, f"invalid implementation_status {implementation!r}")
        production = _expect_string(spec, "production_status", loc, result)
        if production and production not in PRODUCTION_STATES:
            result.error(loc, f"invalid production_status {production!r}")
        migration = _expect_string(spec, "requirement_id_migration", loc, result)
        if migration not in {"pending", "complete"}:
            result.error(loc, "requirement_id_migration must be 'pending' or 'complete'")
        gap = spec.get("gap")
        if migration == "pending" and gap is None:
            result.error(loc, "pending requirement migration requires an owned, issue-linked gap")
        if gap is not None:
            _validate_gap(gap, f"{loc}.gap", result)
        fingerprint = spec.get("legacy_requirement_fingerprint")
        legacy_count = spec.get("legacy_requirement_count")
        if not isinstance(legacy_count, int) or isinstance(legacy_count, bool) or legacy_count < 0:
            result.error(loc, "legacy_requirement_count must be a non-negative integer")
        if migration == "pending":
            if not isinstance(fingerprint, str) or not FINGERPRINT_RE.fullmatch(fingerprint):
                result.error(loc, "pending migration requires a sha256 legacy_requirement_fingerprint")
        elif fingerprint is not None or legacy_count != 0:
            result.error(loc, "complete migration requires null fingerprint and zero legacy requirements")
        reconciled_commit = spec.get("last_reconciled_commit")
        reconciled_at = spec.get("last_reconciled_at")
        if reconciled_commit is not None and (not isinstance(reconciled_commit, str) or not COMMIT_RE.fullmatch(reconciled_commit)):
            result.error(loc, "last_reconciled_commit must be null or a full commit SHA")
        reconciled_date = None
        if reconciled_at is not None:
            reconciled_date = _expect_date(reconciled_at, f"{loc}.last_reconciled_at", result)
            if reconciled_date and reconciled_date > today:
                result.error(loc, "last_reconciled_at is in the future")
        if (reconciled_commit is None) != (reconciled_at is None):
            result.error(loc, "last_reconciled_commit and last_reconciled_at must be set together")
        _validate_evidence_list(spec.get("evidence"), f"{loc}.evidence", result, today, root)
        if "deprecation_rationale" in spec:
            _expect_string(spec, "deprecation_rationale", loc, result)
        valid_specs.append(spec)

    requirement_records = value.get("requirements")
    if not isinstance(requirement_records, list):
        result.error(location, "field 'requirements' must be an array")
        requirement_records = []
    valid_requirements: list[dict[str, Any]] = []
    req_required = {
        "requirement_id", "spec_id", "state", "implementation", "tests",
        "journeys", "evidence", "gap",
    }
    for index, requirement in enumerate(requirement_records):
        loc = f"{location}.requirements[{index}]"
        if not _expect_object(requirement, loc, result):
            continue
        _expect_keys(requirement, req_required, req_required, loc, result)
        requirement_id = _expect_string(requirement, "requirement_id", loc, result, REQUIREMENT_ID_RE)
        spec_id = _expect_string(requirement, "spec_id", loc, result, SPEC_ID_RE)
        if requirement_id and spec_id and requirement_id[:8] != spec_id:
            result.error(loc, f"requirement ID {requirement_id} does not belong to {spec_id}")
        state = _expect_string(requirement, "state", loc, result)
        if state and state not in CONFORMANCE_STATES:
            result.error(loc, f"invalid conformance state {state!r}; allowed: {sorted(CONFORMANCE_STATES)}")
        implementation = _expect_string_list(requirement, "implementation", loc, result)
        tests = _expect_string_list(requirement, "tests", loc, result)
        journeys = _expect_string_list(requirement, "journeys", loc, result)
        _validate_mapping_paths(implementation, "implementation", loc, root, result)
        _validate_mapping_paths(tests, "test", loc, root, result)
        for journey in journeys:
            if not JOURNEY_RE.fullmatch(journey):
                result.error(loc, f"journey mapping has invalid ID {journey!r}")
                continue
            journey_path = root / "journeys" / f"{journey}.md"
            if not journey_path.is_file():
                result.error(loc, f"journey mapping has no tracked record: {journey_path.relative_to(root)}")
        evidence = _validate_evidence_list(requirement.get("evidence"), f"{loc}.evidence", result, today, root)
        gap = requirement.get("gap")
        if state in {"pending", "blocked", "nonconformant"} and gap is None:
            result.error(loc, f"state {state!r} requires an owned, issue-linked gap")
        if state == "not-applicable" and gap is None:
            result.error(loc, "state 'not-applicable' requires owner, issue, and rationale in gap")
        if gap is not None:
            _validate_gap(gap, f"{loc}.gap", result)
            if state == "not-applicable" and isinstance(gap, dict) and not gap.get("rationale"):
                result.error(f"{loc}.gap", "not-applicable requires a non-empty rationale")
        if state == "conformant":
            if not implementation:
                result.error(loc, "conformant requirement requires implementation mapping")
            if not tests and not journeys:
                result.error(loc, "conformant requirement requires a test or journey mapping")
            if not evidence:
                result.error(loc, "conformant requirement requires current evidence")
            commit_artifacts = [
                item["artifact"].removeprefix("commit:") for item in evidence
                if isinstance(item.get("artifact"), str) and item["artifact"].startswith("commit:")
            ]
            if not commit_artifacts:
                result.error(loc, "conformant requirement requires reachable commit evidence for its code mappings")
            elif (root / ".git").exists() and not any(
                _commit_covers_mappings(root, commit, implementation + tests)
                for commit in commit_artifacts
            ):
                result.error(
                    loc,
                    "no evidence commit matches every current mapped implementation/test file and selector",
                )
            if gap is not None:
                result.error(loc, "conformant requirement must not retain a gap")
        valid_requirements.append(requirement)
    return valid_specs, valid_requirements, baseline


def _nested(value: dict[str, Any], *keys: str) -> Any:
    current: Any = value
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def _validate_tracked_schemas(root: Path, result: ValidationResult) -> None:
    for name, expected in TRACKED_SCHEMA_SHA256.items():
        path = root / "schemas" / name
        try:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as exc:
            result.error("schemas", f"cannot fingerprint tracked schema {name}: {exc}")
            continue
        if actual != expected:
            result.error(
                "schemas",
                f"tracked schema/runtime contract drift for {name}: "
                f"expected sha256:{expected}, got sha256:{actual}",
            )
    authority = _load_json(root / "schemas" / "spec-authority-v1.schema.json", result)
    conformance = _load_json(root / "schemas" / "spec-conformance-v1.schema.json", result)
    if not isinstance(authority, dict) or not isinstance(conformance, dict):
        return
    def enum_values(value: Any, name: str) -> set[str]:
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            result.error("schemas", f"tracked schema {name} must be an array of strings")
            return set()
        return set(value)

    checks = [
        (authority.get("type"), "object", "authority root type"),
        (authority.get("additionalProperties"), False, "authority additionalProperties"),
        (_nested(authority, "properties", "schema_version", "const"), "spec-authority-v1", "authority schema version"),
        (enum_values(_nested(authority, "$defs", "domain", "properties", "status", "enum"), "authority status enum"), AUTHORITY_STATES, "authority status enum"),
        (conformance.get("type"), "object", "conformance root type"),
        (conformance.get("additionalProperties"), False, "conformance additionalProperties"),
        (_nested(conformance, "properties", "schema_version", "const"), "spec-conformance-v1", "conformance schema version"),
        (enum_values(_nested(conformance, "$defs", "spec", "properties", "status", "enum"), "lifecycle enum"), LIFECYCLE_STATES, "lifecycle enum"),
        (enum_values(_nested(conformance, "$defs", "spec", "properties", "implementation_status", "enum"), "implementation enum"), IMPLEMENTATION_STATES, "implementation enum"),
        (enum_values(_nested(conformance, "$defs", "spec", "properties", "production_status", "enum"), "production enum"), PRODUCTION_STATES, "production enum"),
        (enum_values(_nested(conformance, "$defs", "requirement", "properties", "state", "enum"), "conformance enum"), CONFORMANCE_STATES, "conformance enum"),
        (enum_values(_nested(conformance, "$defs", "gap", "properties", "verdict", "enum"), "arbitration verdict enum"), VERDICTS, "arbitration verdict enum"),
    ]
    for actual, expected, name in checks:
        if actual != expected:
            result.error("schemas", f"tracked schema/runtime contract drift for {name}: expected {expected!r}, got {actual!r}")


def _canonical_specs(root: Path, result: ValidationResult) -> dict[str, Path]:
    canonical: dict[str, Path] = {}
    for path in sorted((root / "specs").glob("SPEC-*.md")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError as exc:
            result.error(str(path.relative_to(root)), f"invalid UTF-8: {exc}")
            continue
        except OSError as exc:
            result.error(str(path.relative_to(root)), f"cannot read spec: {exc}")
            continue
        if not lines:
            result.error(str(path.relative_to(root)), "canonical candidate is empty")
            continue
        title = TITLE_RE.fullmatch(lines[0].strip())
        if not title:
            result.error(str(path.relative_to(root)), "first line must be '# SPEC-NNN — Title'")
            continue
        if not any(
            VERSION_RE.match(line.replace("*", "").strip())
            or STATUS_VERSION_RE.match(line.replace("*", "").strip())
            for line in lines[:15]
        ):
            result.error(str(path.relative_to(root)), "version header must appear within first 15 lines")
            continue
        spec_id = title.group(1)
        if not path.name.startswith(f"{spec_id}-"):
            result.error(str(path.relative_to(root)), f"title ID {spec_id} does not match filename")
        if spec_id in canonical:
            result.error(str(path.relative_to(root)), f"duplicate canonical spec ID {spec_id}; first at {canonical[spec_id].relative_to(root)}")
        canonical[spec_id] = path
    return canonical


def _resolve_base_commit(root: Path, base_ref: str | None, result: ValidationResult) -> str | None:
    if not (root / ".git").exists() or not base_ref:
        return None
    resolved = subprocess.run(
        ["git", "rev-parse", "--verify", f"{base_ref}^{{commit}}"],
        cwd=root, capture_output=True, text=True,
    )
    commit = resolved.stdout.strip()
    if resolved.returncode or not COMMIT_RE.fullmatch(commit):
        result.error("git", f"base ref {base_ref!r} is not a reachable commit")
        return None
    return commit


def _git_show(root: Path, commit: str, relative: str) -> str | None:
    shown = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=root, capture_output=True, text=True,
    )
    return shown.stdout if shown.returncode == 0 else None


def _validate_base_identities(
    root: Path, base_commit: str | None, canonical: dict[str, Path],
    definitions: dict[str, list[Path]], domains: dict[str, dict[str, Any]],
    specs: dict[str, dict[str, Any]], result: ValidationResult,
) -> None:
    if not base_commit:
        return
    tree = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", base_commit, "specs"],
        cwd=root, capture_output=True, text=True,
    )
    base_spec_ids: set[str] = set()
    base_requirement_ids: set[str] = set()
    base_requirements_by_spec: dict[str, set[str]] = {}
    base_legacy_by_spec: dict[str, Counter[str]] = {}
    for relative in tree.stdout.splitlines():
        match = re.match(r"^specs/(SPEC-\d{3})-.*\.md$", relative)
        if not match:
            continue
        text = _git_show(root, base_commit, relative)
        if text is None or not text.startswith(f"# {match.group(1)}"):
            continue
        base_spec_ids.add(match.group(1))
        found_requirements = set(REQUIREMENT_DEFINITION_RE.findall(_contract_markdown(text)))
        base_requirement_ids.update(found_requirements)
        base_requirements_by_spec[match.group(1)] = found_requirements
        base_legacy_by_spec[match.group(1)] = Counter(_legacy_normative_lines(text))
    for spec_id in sorted(base_spec_ids - canonical.keys()):
        result.error("specs", f"canonical identity {spec_id} cannot be deleted; deprecate it with a tombstone")
    for requirement_id in sorted(base_requirement_ids - definitions.keys()):
        result.error("specs", f"stable requirement identity {requirement_id} cannot be deleted or reused")

    base_authority_text = _git_show(root, base_commit, "specs/AUTHORITY.json")
    if base_authority_text:
        try:
            base_authority = json.loads(base_authority_text)
        except json.JSONDecodeError:
            result.error("git", "base specs/AUTHORITY.json is invalid JSON")
        else:
            for item in base_authority.get("domains", []):
                if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                    continue
                domain_id = item["id"]
                if domain_id not in domains:
                    result.error("specs/AUTHORITY.json", f"authority identity {domain_id!r} cannot be deleted")
                elif domains[domain_id].get("owner_spec") != item.get("owner_spec"):
                    result.error("specs/AUTHORITY.json", f"authority owner for {domain_id!r} cannot change without a versioned governance migration")
                elif item.get("status") == "deprecated" and domains[domain_id].get("status") != "deprecated":
                    result.error("specs/AUTHORITY.json", f"deprecated authority tombstone {domain_id!r} cannot be revived")

    base_conformance_text = _git_show(root, base_commit, "specs/CONFORMANCE.json")
    if base_conformance_text:
        try:
            base_conformance = json.loads(base_conformance_text)
        except json.JSONDecodeError:
            result.error("git", "base specs/CONFORMANCE.json is invalid JSON")
        else:
            for spec_id, base_lines in base_legacy_by_spec.items():
                current_path = canonical.get(spec_id)
                if current_path is None:
                    continue
                current_lines = Counter(_legacy_normative_lines(current_path.read_text(encoding="utf-8")))
                removed_count = sum((base_lines - current_lines).values())
                new_requirements = {
                    requirement_id for requirement_id in definitions
                    if requirement_id.startswith(f"{spec_id}-")
                } - base_requirements_by_spec.get(spec_id, set())
                if removed_count > len(new_requirements):
                    result.error(
                        str(current_path.relative_to(root)),
                        f"removed {removed_count} legacy normative obligation line(s) but added only {len(new_requirements)} stable requirement tombstone(s)",
                    )
            for item in base_conformance.get("specs", []):
                if not isinstance(item, dict) or not isinstance(item.get("spec_id"), str):
                    continue
                current = specs.get(item["spec_id"])
                if current is None:
                    continue
                old_status = item.get("status")
                new_status = current.get("status")
                if isinstance(old_status, str) and isinstance(new_status, str) and new_status not in LIFECYCLE_TRANSITIONS.get(old_status, set()):
                    result.error("specs/CONFORMANCE.json", f"invalid lifecycle transition for {item['spec_id']}: {old_status} -> {new_status}")
                if old_status == "draft" and new_status == "normative":
                    current_requirements = [
                        requirement_id for requirement_id in definitions
                        if requirement_id.startswith(f"{item['spec_id']}-")
                    ]
                    if current.get("requirement_id_migration") != "complete" or not current_requirements:
                        result.error("specs/CONFORMANCE.json", f"{item['spec_id']} draft -> normative requires complete ID migration and at least one stable requirement")
                if current.get("owner") != item.get("owner"):
                    result.error("specs/CONFORMANCE.json", f"owner for {item['spec_id']} cannot change without a versioned governance migration")


def validate_repository(
    root: Path, today: date | None = None, base_ref: str | None = "origin/main",
) -> ValidationResult:
    root = root.resolve()
    today = today or date.today()
    result = ValidationResult()
    base_commit = _resolve_base_commit(root, base_ref, result)
    _validate_tracked_schemas(root, result)
    authority_value = _load_json(root / "specs" / "AUTHORITY.json", result)
    conformance_value = _load_json(root / "specs" / "CONFORMANCE.json", result)
    domains, authority_baseline = (
        _validate_authority_schema(authority_value, result, today)
        if authority_value is not None else ([], (None, None))
    )
    specs, requirements, conformance_baseline = (
        _validate_conformance_schema(conformance_value, result, today, root)
        if conformance_value is not None else ([], [], (None, None))
    )
    if authority_baseline != conformance_baseline:
        result.error("specs", "AUTHORITY.json and CONFORMANCE.json baselines must match exactly")
    baseline_commit = authority_baseline[0]
    baseline_legacy: dict[str, Counter[str]] = {}
    baseline_fingerprints: dict[str, tuple[str, int]] = {}
    if baseline_commit and (root / ".git").exists():
        check = subprocess.run(
            ["git", "cat-file", "-e", f"{baseline_commit}^{{commit}}"],
            cwd=root, capture_output=True, text=True,
        )
        if check.returncode:
            result.error("specs", f"baseline commit {baseline_commit} is not reachable in this repository")
        else:
            tree = subprocess.run(
                ["git", "ls-tree", "-r", "--name-only", baseline_commit, "specs"],
                cwd=root, capture_output=True, text=True,
            )
            for relative in tree.stdout.splitlines():
                match = re.match(r"^specs/(SPEC-\d{3})-.*\.md$", relative)
                if not match:
                    continue
                shown = subprocess.run(
                    ["git", "show", f"{baseline_commit}:{relative}"],
                    cwd=root, capture_output=True, text=True,
                )
                if shown.returncode == 0:
                    baseline_legacy[match.group(1)] = Counter(_legacy_normative_lines(shown.stdout))
                    baseline_fingerprints[match.group(1)] = legacy_requirement_fingerprint(shown.stdout)
    canonical = _canonical_specs(root, result)

    spec_records: dict[str, dict[str, Any]] = {}
    for index, record in enumerate(specs):
        spec_id = record.get("spec_id")
        if not isinstance(spec_id, str):
            continue
        if spec_id in spec_records:
            result.error(f"specs/CONFORMANCE.json.specs[{index}]", f"duplicate spec record for {spec_id}")
        spec_records[spec_id] = record
        rel_path = record.get("path")
        if not isinstance(rel_path, str):
            continue
        path = (root / rel_path).resolve()
        try:
            path.relative_to(root)
        except ValueError:
            result.error(f"specs/CONFORMANCE.json.specs[{index}]", f"path escapes repository: {rel_path!r}")
            continue
        if not path.is_file():
            result.error(f"specs/CONFORMANCE.json.specs[{index}]", f"referenced SPEC file does not exist: {rel_path}")
        elif canonical.get(spec_id) != path:
            result.error(f"specs/CONFORMANCE.json.specs[{index}]", f"path {rel_path!r} is not the canonical file for {spec_id}")
        else:
            text = path.read_text(encoding="utf-8")
            lines = text.splitlines()
            title_match = TITLE_RE.fullmatch(lines[0].strip()) if lines else None
            header_version = None
            for line in lines[:15]:
                clean = line.replace("*", "").strip()
                match = re.match(r"^Version:\s*(\S+)", clean, re.IGNORECASE)
                if match:
                    header_version = match.group(1).rstrip(".,;")
                    break
                match = re.match(r"^Status:.*?\b(v?\d+\.\d+(?:\.\d+)?)", clean, re.IGNORECASE)
                if match:
                    header_version = match.group(1)
                    break
            if title_match and record.get("title") != title_match.group(2).strip():
                result.error(f"specs/CONFORMANCE.json.specs[{index}]", "title does not match canonical spec header")
            if header_version and record.get("version") != header_version:
                result.error(f"specs/CONFORMANCE.json.specs[{index}]", f"version {record.get('version')!r} does not match header {header_version!r}")
            fingerprint, count = legacy_requirement_fingerprint(text)
            current_legacy = Counter(_legacy_normative_lines(text))
            if spec_id in baseline_legacy:
                additions = current_legacy - baseline_legacy[spec_id]
                if additions:
                    sample = next(iter(additions))
                    result.error(
                        f"specs/CONFORMANCE.json.specs[{index}]",
                        f"new or changed unnumbered normative obligation is forbidden: {sample!r}; assign a stable requirement ID",
                    )
            elif current_legacy:
                result.error(
                    f"specs/CONFORMANCE.json.specs[{index}]",
                    "new spec contains unnumbered normative obligations; assign stable requirement IDs",
                )
            if record.get("requirement_id_migration") == "pending":
                expected_fingerprint = baseline_fingerprints.get(spec_id, (fingerprint, count))
                if (record.get("legacy_requirement_fingerprint"), record.get("legacy_requirement_count")) != expected_fingerprint:
                    result.error(
                        f"specs/CONFORMANCE.json.specs[{index}]",
                        "legacy normative obligation ledger must match the pinned bootstrap baseline",
                    )
            elif count:
                result.error(
                    f"specs/CONFORMANCE.json.specs[{index}]",
                    f"requirement migration is complete but {count} unnumbered normative obligation line(s) remain",
                )

    for spec_id, path in canonical.items():
        if spec_id not in spec_records:
            result.error(str(path.relative_to(root)), f"missing conformance spec record for {spec_id}")
    for spec_id in sorted(spec_records.keys() - canonical.keys()):
        result.error("specs/CONFORMANCE.json", f"record references non-canonical or missing {spec_id}")
    for spec_id, record in spec_records.items():
        for field_name in ("supersedes", "depends_on", "superseded_by"):
            values = record.get(field_name)
            for referenced_spec in values if isinstance(values, list) else []:
                if not isinstance(referenced_spec, str):
                    continue
                if referenced_spec not in canonical:
                    result.error("specs/CONFORMANCE.json", f"{spec_id} {field_name} references missing {referenced_spec}")

    domain_records: dict[str, dict[str, Any]] = {}
    for index, domain in enumerate(domains):
        domain_id = domain.get("id")
        owner_spec = domain.get("owner_spec")
        if not isinstance(domain_id, str):
            continue
        if domain_id in domain_records:
            previous = domain_records[domain_id].get("owner_spec")
            result.error(
                f"specs/AUTHORITY.json.domains[{index}]",
                f"duplicate authority ownership for {domain_id!r}: {previous} and {owner_spec}",
            )
        domain_records[domain_id] = domain
        if not isinstance(owner_spec, str):
            continue
        if owner_spec not in canonical:
            result.error(f"specs/AUTHORITY.json.domains[{index}]", f"owner_spec {owner_spec!r} is not canonical")
        consumers = domain.get("consumers")
        for consumer in consumers if isinstance(consumers, list) else []:
            if not isinstance(consumer, str):
                continue
            if consumer not in canonical:
                result.error(f"specs/AUTHORITY.json.domains[{index}]", f"consumer {consumer!r} is not canonical")

    for domain_id, domain in domain_records.items():
        owner_spec = domain.get("owner_spec")
        if not isinstance(owner_spec, str):
            continue
        owner_record = spec_records.get(owner_spec, {})
        if owner_record.get("status") == "deprecated" and domain.get("status") != "deprecated":
            result.error(
                "specs/AUTHORITY.json",
                f"authority domain {domain_id!r} owned by deprecated {owner_spec} must be a deprecated tombstone",
            )
        if domain.get("status") == "deprecated":
            continue
        declared = owner_record.get("authority_domains")
        if domain_id not in (declared if isinstance(declared, list) else []):
            result.error("specs/CONFORMANCE.json", f"owner {owner_spec} does not declare authority domain {domain_id!r}")
    for spec_id, record in spec_records.items():
        declared = record.get("authority_domains")
        for domain_id in declared if isinstance(declared, list) else []:
            if not isinstance(domain_id, str):
                continue
            domain = domain_records.get(domain_id)
            if domain is None:
                result.error("specs/CONFORMANCE.json", f"{spec_id} declares unknown authority domain {domain_id!r}")
            elif domain.get("owner_spec") != spec_id:
                result.error("specs/CONFORMANCE.json", f"{spec_id} declares {domain_id!r}, owned by {domain.get('owner_spec')}")
            elif domain.get("status") == "deprecated":
                result.error("specs/CONFORMANCE.json", f"{spec_id} cannot declare deprecated authority domain {domain_id!r}")

    definitions: dict[str, list[Path]] = {}
    requirement_references: dict[str, list[Path]] = {}
    for spec_id, path in canonical.items():
        text = path.read_text(encoding="utf-8")
        contract_text = _contract_markdown(text)
        for requirement_id in REQUIREMENT_DEFINITION_RE.findall(contract_text):
            definitions.setdefault(requirement_id, []).append(path)
            if requirement_id[:8] != spec_id:
                result.error(str(path.relative_to(root)), f"requirement {requirement_id} must use owning prefix {spec_id}")
        for reference in sorted(set(SPEC_REFERENCE_RE.findall(contract_text))):
            if reference not in canonical:
                result.error(str(path.relative_to(root)), f"broken cross-spec reference {reference}; no canonical spec exists")
        for requirement_reference in sorted(set(REQUIREMENT_REFERENCE_RE.findall(contract_text))):
            requirement_references.setdefault(requirement_reference, []).append(path)
        for target in MARKDOWN_LINK_RE.findall(text):
            target = target.strip().split("#", 1)[0]
            if not target or re.match(r"^(?:https?://|mailto:)", target):
                continue
            linked = (path.parent / target).resolve()
            try:
                linked.relative_to(root)
            except ValueError:
                result.error(str(path.relative_to(root)), f"Markdown link escapes repository: {target!r}")
                continue
            if not linked.exists():
                result.error(str(path.relative_to(root)), f"broken Markdown link target {target!r}")
    for requirement_id, paths in definitions.items():
        if len(paths) > 1:
            locations = ", ".join(str(path.relative_to(root)) for path in paths)
            result.error(locations, f"duplicate requirement definition {requirement_id}")
    for requirement_id, paths in requirement_references.items():
        if requirement_id not in definitions:
            result.error(str(paths[0].relative_to(root)), f"broken requirement reference {requirement_id}; no definition exists")

    requirement_records: dict[str, dict[str, Any]] = {}
    for index, record in enumerate(requirements):
        requirement_id = record.get("requirement_id")
        if not isinstance(requirement_id, str):
            continue
        if requirement_id in requirement_records:
            result.error(f"specs/CONFORMANCE.json.requirements[{index}]", f"duplicate requirement mapping {requirement_id}")
        requirement_records[requirement_id] = record
        mapped_spec_id = record.get("spec_id")
        if not isinstance(mapped_spec_id, str) or mapped_spec_id not in canonical:
            result.error(f"specs/CONFORMANCE.json.requirements[{index}]", f"spec_id {mapped_spec_id!r} is not canonical")
        if requirement_id not in definitions:
            result.error(f"specs/CONFORMANCE.json.requirements[{index}]", f"mapping references undefined requirement {requirement_id}")
    for requirement_id, paths in definitions.items():
        if requirement_id not in requirement_records:
            result.error(str(paths[0].relative_to(root)), f"missing conformance reference for {requirement_id}")

    _validate_base_identities(
        root, base_commit, canonical, definitions, domain_records, spec_records, result,
    )

    requirements_by_spec: dict[str, list[dict[str, Any]]] = {}
    for record in requirements:
        spec_id = record.get("spec_id")
        if isinstance(spec_id, str):
            requirements_by_spec.setdefault(spec_id, []).append(record)
    for spec_id, record in spec_records.items():
        status = record.get("status")
        migration = record.get("requirement_id_migration")
        gap = record.get("gap")
        owned_requirements = requirements_by_spec.get(spec_id, [])
        domains_for_spec = record.get("authority_domains")
        domains_for_spec = domains_for_spec if isinstance(domains_for_spec, list) else []
        if status == "implemented-unverified":
            if migration != "complete" or record.get("implementation_status") != "implemented":
                result.error("specs/CONFORMANCE.json", f"{spec_id} implemented-unverified requires complete ID migration and implementation_status='implemented'")
            if not owned_requirements:
                result.error("specs/CONFORMANCE.json", f"{spec_id} implemented-unverified requires at least one owned requirement")
            for requirement in owned_requirements:
                if not requirement.get("implementation") or not requirement.get("evidence"):
                    result.error("specs/CONFORMANCE.json", f"{spec_id} implemented-unverified requires implementation mappings and current evidence for every owned requirement")
                    continue
                commit_artifacts = [
                    item.get("artifact", "").removeprefix("commit:")
                    for item in requirement.get("evidence", []) if isinstance(item, dict)
                    and isinstance(item.get("artifact"), str) and item["artifact"].startswith("commit:")
                ]
                if not commit_artifacts or ((root / ".git").exists() and not any(
                    _commit_covers_mappings(root, commit, requirement.get("implementation", []))
                    for commit in commit_artifacts
                )):
                    result.error("specs/CONFORMANCE.json", f"{spec_id} implemented-unverified requires a reachable evidence commit containing every implementation selector")
        if status == "physically-verified":
            result.error("specs/CONFORMANCE.json", f"{spec_id} cannot become physically-verified until the structured Phase 5 journey-result contract is enforced")
            if migration != "complete" or gap is not None:
                result.error("specs/CONFORMANCE.json", f"{spec_id} physically-verified requires complete ID migration and no gap")
            if record.get("implementation_status") != "implemented" or record.get("production_status") != "physically-verified":
                result.error("specs/CONFORMANCE.json", f"{spec_id} physically-verified requires implemented code and physically verified production")
            if not owned_requirements or any(item.get("state") != "conformant" for item in owned_requirements):
                result.error("specs/CONFORMANCE.json", f"{spec_id} physically-verified requires every owned requirement to be conformant")
        if status == "deprecated":
            if domains_for_spec:
                result.error("specs/CONFORMANCE.json", f"deprecated {spec_id} must not retain authority domains")
            successors = record.get("superseded_by")
            rationale = record.get("deprecation_rationale")
            if not successors and not rationale:
                result.error("specs/CONFORMANCE.json", f"deprecated {spec_id} requires superseded_by or deprecation_rationale")
        if any(isinstance(domain, str) and domain in SENSITIVE_PHYSICAL_DOMAINS for domain in domains_for_spec):
            for requirement in owned_requirements:
                if requirement.get("state") == "conformant" and not requirement.get("journeys"):
                    result.error("specs/CONFORMANCE.json", f"sensitive conformant {requirement.get('requirement_id')} requires a physical journey mapping")
                if requirement.get("state") == "conformant":
                    result.error("specs/CONFORMANCE.json", f"sensitive {requirement.get('requirement_id')} cannot become conformant until structured physical journey results are enforced")
                    physical_artifact = any(
                        isinstance(item, dict)
                        and isinstance(item.get("artifact"), str)
                        and item["artifact"].startswith("sha256:")
                        and isinstance(item.get("source"), str)
                        and _is_physical_evidence_path(root, item["source"])
                        for item in requirement.get("evidence", [])
                    )
                    if not physical_artifact:
                        result.error("specs/CONFORMANCE.json", f"sensitive conformant {requirement.get('requirement_id')} requires sha256 journey evidence under journeys/evidence/")

    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--today", type=date.fromisoformat, help="validation date override (tests only)")
    parser.add_argument("--base-ref", default="origin/main", help="trusted base commit/ref for append-only identity and lifecycle checks")
    args = parser.parse_args(argv)
    result = validate_repository(args.root, args.today, args.base_ref)
    if result.errors:
        print(f"spec governance validation failed with {len(result.errors)} error(s):", file=sys.stderr)
        for error in result.errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("ok: spec governance manifests, authority, requirements, references, gaps, and evidence are valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
