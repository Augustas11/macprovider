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
import html
from html.parser import HTMLParser
import json
import re
import string
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
CODE_SPAN_START = "\x00code-span-start\x00"
CODE_SPAN_END = "\x00code-span-end\x00"

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
    "search|section|source|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul"
)
RAW_HTML_BLOCK_TAG_RE = re.compile(
    rf" {{0,3}}</?(?:{RAW_HTML_BLOCK_TAGS})(?:\s|/?>|$)",
    re.IGNORECASE,
)
RAW_HTML_ATTRIBUTE = (
    r"(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*"
    r"(?:\s*=\s*(?:[^ \"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*"
)
RAW_HTML_COMPLETE_TAG_RE = re.compile(
    rf" {{0,3}}(?:"
    rf"<[A-Za-z][A-Za-z0-9-]*{RAW_HTML_ATTRIBUTE}\s*/?>|"
    r"</[A-Za-z][A-Za-z0-9-]*\s*>)"
    r"[ \t]*$",
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


def _strip_container_markers(line: str) -> str:
    """Remove explicit nested blockquote/list markers from one block-start line."""
    return _block_line_context(line)[0]


ContainerContext = tuple[tuple[str, int], ...]


def _block_line_context(line: str) -> tuple[str, ContainerContext]:
    """Return block content and the explicit containers that own its opener."""
    content = line
    containers: list[tuple[str, int]] = []
    while True:
        consumed = False
        quote = re.match(r" {0,3}>[ \t]?", content)
        if quote is not None:
            content = content[quote.end():]
            containers.append(("quote", 0))
            consumed = True

        list_item = re.match(
            r"( {0,3})(?:[*+-]|\d{1,9}[.)])([ \t]+|$)",
            content,
        )
        if list_item is not None:
            prefix = list_item.group(0)
            content = content[list_item.end():]
            containers.append(("list", len(prefix.expandtabs(4))))
            consumed = True
        if not consumed:
            break
    return content, tuple(containers)


def _line_in_container(line: str, container: ContainerContext) -> str | None:
    """Return content relative to an opener's container, or None after exit."""
    content = line
    for kind, width in container:
        if kind == "quote":
            quote = re.match(r" {0,3}>[ \t]?", content)
            if quote is None:
                return None
            content = content[quote.end():]
            continue

        if not content.strip():
            content = ""
            continue
        cursor = 0
        columns = 0
        while cursor < len(content) and columns < width:
            character = content[cursor]
            if character == " ":
                columns += 1
            elif character == "\t":
                columns += 4 - (columns % 4)
            else:
                break
            cursor += 1
        if columns < width:
            return None
        content = content[cursor:]
    return content


def _link_continuation_content(
    line: str,
    container: ContainerContext,
) -> str | None:
    """Return continuation content unless a new block container interrupts it."""
    content = _line_in_container(line, container)
    if content is None:
        if not container:
            return None
        content = line
    if re.match(
        r" {0,3}(?:>|[*+-](?:[ \t]+|$)|\d{1,9}[.)](?:[ \t]+|$))",
        content,
    ) or _starts_interrupting_raw_html(content) or not _paragraph_remains_open(
        content,
        True,
    ):
        return None
    return content


def _link_definition_remainder(content: str) -> str | None:
    """Return text after a valid CommonMark link label and colon."""
    leading = re.match(r" {0,3}", content)
    cursor = leading.end() if leading is not None else 0
    if cursor >= len(content) or content[cursor] != "[":
        return None
    cursor += 1
    label_start = cursor
    visible_label: list[str] = []
    while cursor < len(content):
        character = content[cursor]
        if (
            character == "\\"
            and cursor + 1 < len(content)
            and content[cursor + 1] in string.punctuation
        ):
            visible_label.append(content[cursor + 1])
            cursor += 2
            continue
        if character == "[":
            return None
        if character == "]":
            break
        visible_label.append(character)
        cursor += 1
    if cursor >= len(content) or content[cursor] != "]":
        return None
    if cursor - label_start > 999 or not "".join(visible_label).strip():
        return None
    cursor += 1
    if cursor >= len(content) or content[cursor] != ":":
        return None
    return content[cursor + 1:]


def _valid_link_title(value: str) -> bool:
    if len(value) < 2:
        return False
    closing = {'"': '"', "'": "'", "(": ")"}.get(value[0])
    if closing is None or value[-1] != closing:
        return False
    trailing_backslashes = len(value[:-1]) - len(value[:-1].rstrip("\\"))
    if trailing_backslashes % 2:
        return False
    inner = value[1:-1]
    cursor = 0
    while cursor < len(inner):
        character = inner[cursor]
        if (
            character == "\\"
            and cursor + 1 < len(inner)
            and inner[cursor + 1] in string.punctuation
        ):
            cursor += 2
            continue
        if character == closing or (value[0] == "(" and character == "("):
            return False
        if ord(character) < 0x20 and character not in "\t\n":
            return False
        cursor += 1
    return True


def _valid_bare_link_destination(value: str) -> bool:
    if not value:
        return False
    depth = 0
    cursor = 0
    while cursor < len(value):
        character = value[cursor]
        if (
            character == "\\"
            and cursor + 1 < len(value)
            and value[cursor + 1] in string.punctuation
        ):
            cursor += 2
            continue
        if character in "<>" or character.isspace() or ord(character) < 0x20:
            return False
        if character == "(":
            depth += 1
            if depth > 32:
                return False
        elif character == ")":
            depth -= 1
            if depth < 0:
                return False
        cursor += 1
    return depth == 0


def _link_destination_parts(value: str) -> tuple[bool, str | None, bool]:
    """Return destination validity, optional title text, and title eligibility."""
    text = value.strip()
    if not text:
        return False, None, False
    if text.startswith("<"):
        cursor = 1
        while cursor < len(text):
            character = text[cursor]
            if (
                character == "\\"
                and cursor + 1 < len(text)
                and text[cursor + 1] in string.punctuation
            ):
                cursor += 2
                continue
            if character == "<" or ord(character) < 0x20:
                return False, None, False
            if character == ">":
                break
            cursor += 1
        if cursor >= len(text) or text[cursor] != ">":
            return False, None, False
        raw_remainder = text[cursor + 1:]
        if raw_remainder and not raw_remainder[0].isspace():
            return False, None, False
        remainder = raw_remainder.strip()
        return True, remainder or None, True
    else:
        separator = re.search(r"\s", text)
        if separator is None:
            destination = text
            remainder = ""
        else:
            destination = text[:separator.start()]
            remainder = text[separator.end():].strip()
        if not _valid_bare_link_destination(destination):
            return False, None, False
        trailing_backslashes = len(destination) - len(destination.rstrip("\\"))
        allows_title = trailing_backslashes % 2 == 0
        if remainder and not allows_title:
            return False, None, False
        return True, remainder or None, allows_title


def _parse_link_destination_line(value: str) -> tuple[bool, bool]:
    """Return validity and whether a destination line includes a complete title."""
    valid, title, _ = _link_destination_parts(value)
    if not valid:
        return False, False
    if title is not None and not _valid_link_title(title):
        return False, False
    return True, title is not None


def _valid_link_destination_line(value: str) -> bool:
    return _parse_link_destination_line(value)[0]


def _is_single_line_link_definition(content: str) -> bool:
    remainder = _link_definition_remainder(content)
    return remainder is not None and _valid_link_destination_line(remainder)


def _paragraph_remains_open(line: str, was_open: bool) -> bool:
    """Track enough container state to apply CommonMark type-7 start rules."""
    content = _strip_container_markers(line)

    stripped = content.strip()
    if not stripped:
        return False
    if (
        re.match(r" {0,3}#{1,6}(?:\s|$)", content)
        or re.match(r" {0,3}(?:`{3,}|~{3,})", content)
        or re.fullmatch(r" {0,3}(?:-\s*-\s*-[-\s]*|\*\s*\*\s*\*[\s*]*|_\s*_\s*_[\s_]*)", content)
        or (
            was_open
            and re.fullmatch(r" {0,3}(?:=+|-+)[ \t]*", content)
        )
        or (
            not was_open
            and _is_single_line_link_definition(content)
        )
        or (not was_open and content.startswith(("    ", "\t")))
    ):
        return False
    return True


def _starts_interrupting_raw_html(line: str) -> bool:
    """Return whether a CommonMark raw-HTML block can interrupt a paragraph."""
    content = _strip_container_markers(line)
    return bool(
        re.match(
            r" {0,3}<(?:pre|script|style|textarea)(?:\s|>|$)",
            content,
            re.IGNORECASE,
        )
        or re.match(r" {0,3}<!--(?!>|->)", content)
        or re.match(r" {0,3}<\?", content)
        or re.match(r" {0,3}<!\[CDATA\[", content)
        or re.match(r" {0,3}<![A-Z]", content)
        or RAW_HTML_BLOCK_TAG_RE.match(content)
    )


def _breaks_lazy_container_paragraph(line: str) -> bool:
    """Return whether an uncontained line ends a quote/list paragraph."""
    content = line
    return bool(
        not content.strip()
        or re.match(
            r" {0,3}(?:>|[*+-](?:[ \t]+|$)|\d{1,9}[.)](?:[ \t]+|$))",
            content,
        )
        or _starts_interrupting_raw_html(content)
        or RAW_HTML_COMPLETE_TAG_RE.fullmatch(content)
        or not _paragraph_remains_open(content, True)
    )


def _multiline_link_label(
    lines: list[str],
    line_index: int,
) -> tuple[int, str, ContainerContext] | None:
    """Return the closing-label line and text after its colon."""
    content, container = _block_line_context(lines[line_index])
    leading = re.match(r" {0,3}", content)
    cursor = leading.end() if leading is not None else 0
    if cursor >= len(content) or content[cursor] != "[":
        return None
    cursor += 1
    label_length = 0
    visible_label: list[str] = []
    candidate_index = line_index
    while candidate_index < len(lines):
        if candidate_index != line_index:
            content = _link_continuation_content(
                lines[candidate_index],
                container,
            )
            if content is None:
                return None
            cursor = 0
            if not content.strip():
                return None
            label_length += 1
            visible_label.append("\n")
        while cursor < len(content):
            character = content[cursor]
            if (
                character == "\\"
                and cursor + 1 < len(content)
                and content[cursor + 1] in string.punctuation
            ):
                label_length += 2
                visible_label.append(content[cursor + 1])
                cursor += 2
                continue
            if character == "[":
                return None
            if character == "]":
                if cursor + 1 >= len(content) or content[cursor + 1] != ":":
                    return None
                if (
                    label_length == 0
                    or label_length > 999
                    or not "".join(visible_label).strip()
                ):
                    return None
                return candidate_index, content[cursor + 2:], container
            label_length += 1
            visible_label.append(character)
            if label_length > 999:
                return None
            cursor += 1
        candidate_index += 1
    return None


def _link_title_span(
    lines: list[str],
    line_index: int,
    initial: str,
    container: ContainerContext,
) -> int:
    """Return the line span of a complete title beginning at line_index."""
    candidate = initial.strip()
    if not candidate or candidate[0] not in "\"'(":
        return 0
    candidate_index = line_index
    while True:
        if _valid_link_title(candidate):
            return candidate_index - line_index + 1
        closing = {'"': '"', "'": "'", "(": ")"}[candidate[0]]
        cursor = 1
        while cursor < len(candidate):
            character = candidate[cursor]
            if (
                character == "\\"
                and cursor + 1 < len(candidate)
                and candidate[cursor + 1] in string.punctuation
            ):
                cursor += 2
                continue
            if character == closing or (candidate[0] == "(" and character == "("):
                return 0
            cursor += 1
        candidate_index += 1
        if candidate_index >= len(lines):
            return 0
        continuation = _link_continuation_content(
            lines[candidate_index],
            container,
        )
        if continuation is None:
            return 0
        if not continuation.strip():
            return 0
        candidate += "\n" + continuation.strip()


def _link_definition_span(lines: list[str], line_index: int) -> int:
    """Return the validated line span of a CommonMark reference definition."""
    label = _multiline_link_label(lines, line_index)
    if label is None:
        return 0
    label_line, remainder, container = label
    destination_line = label_line
    destination = remainder
    if not destination.strip():
        destination_line += 1
        if destination_line >= len(lines):
            return 0
        destination = _link_continuation_content(
            lines[destination_line],
            container,
        )
        if destination is None:
            return 0

    valid_destination, inline_title, allows_title = _link_destination_parts(
        destination,
    )
    if not valid_destination:
        return 0
    if inline_title is not None:
        title_span = _link_title_span(
            lines,
            destination_line,
            inline_title,
            container,
        )
        if not title_span:
            return 0
        return destination_line + title_span - line_index

    definition_span = destination_line - line_index + 1
    title_line = destination_line + 1
    if allows_title and title_line < len(lines):
        title_content = _link_continuation_content(
            lines[title_line],
            container,
        )
        title = title_content.strip() if title_content is not None else ""
        title_span = _link_title_span(lines, title_line, title, container)
        if title_span:
            definition_span += title_span
    return definition_span


def _multiline_link_definition_span(lines: list[str], line_index: int) -> int:
    """Compatibility wrapper for callers and focused parser tests."""
    return _link_definition_span(lines, line_index)


def _contract_markdown(
    text: str,
    *,
    preserve_code_payload: bool = False,
) -> str:
    """Return contract text with nonnormative block and inline syntax removed."""
    text = text.replace("\x00", "\ufffd")
    raw_lines = text.splitlines()
    lines: list[str] = []
    fence: tuple[str, int, ContainerContext] | None = None
    code_span: int | None = None
    raw_html_end: tuple[re.Pattern[str], ContainerContext] | None = None
    raw_html_blank_container: ContainerContext | None = None
    in_comment = False
    paragraph_open = False
    paragraph_container: ContainerContext | None = None
    link_definition_remaining = 0
    for line_index, raw_line in enumerate(raw_lines):
        block_line, line_container = _block_line_context(raw_line)
        lazy_container_line = False
        if link_definition_remaining:
            link_definition_remaining -= 1
            paragraph_open = False
            lines.append("")
            continue
        if fence is not None:
            delimiter, minimum_length, container = fence
            closing_line = _line_in_container(raw_line, container)
            if closing_line is not None:
                closing = re.fullmatch(r" {0,3}([`~]+)[ \t]*", closing_line)
                if (
                    closing is not None
                    and closing.group(1)[0] == delimiter
                    and len(closing.group(1)) >= minimum_length
                    and set(closing.group(1)) == {delimiter}
                ):
                    fence = None
                paragraph_open = False
                lines.append("")
                continue
            fence = None

        if raw_html_end is not None:
            closing_pattern, container = raw_html_end
            html_line = _line_in_container(raw_line, container)
            if html_line is not None:
                if closing_pattern.search(html_line):
                    raw_html_end = None
                paragraph_open = False
                lines.append("")
                continue
            raw_html_end = None
        if raw_html_blank_container is not None:
            html_line = _line_in_container(raw_line, raw_html_blank_container)
            if html_line is not None:
                if not html_line.strip():
                    raw_html_blank_container = None
                paragraph_open = False
                lines.append("")
                continue
            raw_html_blank_container = None

        if paragraph_open and paragraph_container is not None:
            if paragraph_container:
                if _line_in_container(raw_line, paragraph_container) is None:
                    if _breaks_lazy_container_paragraph(raw_line):
                        paragraph_open = False
                        paragraph_container = None
                    else:
                        lazy_container_line = True
            elif line_container:
                paragraph_open = False
                paragraph_container = None

        if code_span is None and not in_comment:
            link_definition_span = (
                _multiline_link_definition_span(raw_lines, line_index)
                if not paragraph_open else 0
            )
            if link_definition_span:
                link_definition_remaining = link_definition_span - 1
                paragraph_open = False
                lines.append("")
                continue
            if not paragraph_open and raw_line.startswith(("    ", "\t")):
                paragraph_open = False
                lines.append(raw_line)
                continue
            raw_html_opening = re.match(
                r" {0,3}<(pre|script|style|textarea)(?:\s|>|$)",
                block_line,
                re.IGNORECASE,
            )
            if raw_html_opening is not None:
                tag = raw_html_opening.group(1)
                if re.search(rf"</{tag}\s*>", block_line, re.IGNORECASE) is None:
                    raw_html_end = (
                        re.compile(rf"</{tag}\s*>", re.IGNORECASE),
                        line_container,
                    )
                paragraph_open = False
                lines.append("")
                continue
            raw_html_special = (
                (r" {0,3}<!--(?!>|->)", re.compile(r"-->")),
                (r" {0,3}<\?", re.compile(r"\?>")),
                (r" {0,3}<!\[CDATA\[", re.compile(r"\]\]>")),
                (r" {0,3}<![A-Z]", re.compile(r">")),
            )
            matched_special = False
            for opening_pattern, closing_pattern in raw_html_special:
                if re.match(opening_pattern, block_line) is None:
                    continue
                if closing_pattern.search(block_line) is None:
                    raw_html_end = (closing_pattern, line_container)
                matched_special = True
                break
            if matched_special:
                paragraph_open = False
                lines.append("")
                continue
            if (
                RAW_HTML_BLOCK_TAG_RE.match(block_line) is not None
                or (
                    not paragraph_open
                    and RAW_HTML_COMPLETE_TAG_RE.fullmatch(block_line) is not None
                )
            ):
                raw_html_blank_container = line_container
                paragraph_open = False
                lines.append("")
                continue
            opening = re.fullmatch(r" {0,3}(`{3,}|~{3,})(.*)", block_line)
            if opening is not None:
                marker, info = opening.groups()
                if marker[0] == "~" or "`" not in info:
                    fence = (
                        marker[0],
                        len(marker),
                        line_container,
                    )
                    paragraph_open = False
                    lines.append("")
                    continue

        visible: list[str] = []
        cursor = 0
        while cursor < len(raw_line):
            if code_span is not None:
                if raw_line[cursor] != "`":
                    visible.append(raw_line[cursor] if preserve_code_payload else " ")
                    cursor += 1
                    continue
                end = cursor
                while end < len(raw_line) and raw_line[end] == "`":
                    end += 1
                closes_span = end - cursor == code_span
                if preserve_code_payload and closes_span:
                    visible.append(CODE_SPAN_END)
                visible.append(
                    raw_line[cursor:end]
                    if closes_span or preserve_code_payload
                    else " " * (end - cursor)
                )
                if closes_span:
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
                if code_span is not None and preserve_code_payload:
                    visible.append(CODE_SPAN_START)
                cursor = end
                continue
            if (
                raw_line.startswith("<!--", cursor)
                and not raw_line.startswith(("<!-->", "<!--->"), cursor)
                and _has_inline_comment_closer(
                    raw_lines,
                    line_index,
                    cursor + 4,
                )
            ):
                in_comment = True
                cursor += 4
                continue
            visible.append(raw_line[cursor])
            cursor += 1
        line = "".join(visible)
        if lazy_container_line:
            line = "> " + line
        lines.append(line)
        was_open = paragraph_open
        paragraph_open = _paragraph_remains_open(raw_line, paragraph_open)
        if paragraph_open and not was_open:
            paragraph_container = line_container
        elif not paragraph_open:
            paragraph_container = None
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
            if (
                re.match(
                    r" {0,3}(?:>|[*+-](?:[ \t]+|$)|\d{1,9}[.)](?:[ \t]+|$))",
                    candidate,
                )
                or _starts_interrupting_raw_html(candidate)
                or not _paragraph_remains_open(candidate, True)
            ):
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


def _has_inline_comment_closer(
    lines: list[str],
    line_index: int,
    cursor: int,
) -> bool:
    """Return whether an inline HTML comment closes inside this paragraph."""
    content: list[str] = []
    first = lines[line_index][cursor:]
    first_end = first.find("-->")
    if first_end != -1:
        candidate = first[:first_end]
        return "--" not in candidate and not candidate.endswith("-")
    content.append(first)
    if not _paragraph_remains_open(lines[line_index], True):
        return False
    for candidate_index in range(line_index, len(lines)):
        candidate = lines[candidate_index]
        if candidate_index == line_index:
            continue
        if not candidate.strip():
            return False
        if re.match(r" {0,3}(?:>|[*+-](?:[ \t]+|$)|\d{1,9}[.)](?:[ \t]+|$))", candidate):
            return False
        if _starts_interrupting_raw_html(candidate):
            return False
        if not _paragraph_remains_open(candidate, True):
            return False
        cursor = 0
        end = candidate.find("-->", cursor)
        if end != -1:
            content.append(candidate[:end])
            joined = "\n".join(content)
            return "--" not in joined and not joined.endswith("-")
        content.append(candidate)
    return False


def _legacy_normative_lines(text: str) -> list[str]:
    """Return frozen, unnumbered normative lines from contract Markdown."""
    lines: list[str] = []
    in_code_span = False
    for raw_line in _contract_markdown(
        text,
        preserve_code_payload=True,
    ).splitlines():
        visible: list[str] = []
        fingerprint: list[str] = []
        cursor = 0
        while cursor < len(raw_line):
            if raw_line.startswith(CODE_SPAN_START, cursor):
                in_code_span = True
                cursor += len(CODE_SPAN_START)
                continue
            if raw_line.startswith(CODE_SPAN_END, cursor):
                in_code_span = False
                cursor += len(CODE_SPAN_END)
                continue
            fingerprint.append(raw_line[cursor])
            if not in_code_span:
                visible.append(raw_line[cursor])
            cursor += 1
        stripped = "".join(fingerprint).strip()
        visible_text = _visible_inline_text("".join(visible).strip())
        if not NORMATIVE_KEYWORD_RE.search(visible_text):
            continue
        if REQUIREMENT_DEFINITION_RE.match(stripped):
            continue
        lines.append(" ".join(stripped.split()))
    return lines


class _InlineHTMLTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def _balanced_inline_end(
    text: str,
    start: int,
    opener: str,
    closer: str,
    *,
    quote_aware: bool = False,
) -> int | None:
    depth = 0
    quote: str | None = None
    cursor = start
    while cursor < len(text):
        character = text[cursor]
        if character == "\\" and cursor + 1 < len(text):
            cursor += 2
            continue
        if quote_aware and quote is not None:
            if character == quote:
                quote = None
            cursor += 1
            continue
        if quote_aware and character in {'"', "'"}:
            quote = character
            cursor += 1
            continue
        if character == opener:
            depth += 1
        elif character == closer:
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    return None


def _inline_link_labels(text: str) -> str:
    """Replace inline/reference link syntax with its rendered label."""
    rendered: list[str] = []
    cursor = 0
    while cursor < len(text):
        image = text.startswith("![", cursor)
        label_start = cursor + 1 if image else cursor
        if text[label_start:label_start + 1] != "[":
            rendered.append(text[cursor])
            cursor += 1
            continue
        label_end = _balanced_inline_end(text, label_start, "[", "]")
        if label_end is None:
            rendered.append(text[cursor])
            cursor += 1
            continue
        label = _inline_link_labels(text[label_start + 1:label_end])
        suffix = label_end + 1
        if suffix < len(text) and text[suffix] == "(":
            destination_end = _balanced_inline_end(
                text,
                suffix,
                "(",
                ")",
                quote_aware=True,
            )
            if destination_end is None:
                rendered.append(text[cursor])
                cursor += 1
                continue
            rendered.append(label)
            cursor = destination_end + 1
            continue
        if suffix < len(text) and text[suffix] == "[":
            reference_end = _balanced_inline_end(text, suffix, "[", "]")
            if reference_end is not None:
                rendered.append(label)
                cursor = reference_end + 1
                continue
        rendered.append(label)
        cursor = label_end + 1
    return "".join(rendered)


def _visible_inline_text(text: str) -> str:
    """Return conservative rendered text for reserved-token scans."""
    parser = _InlineHTMLTextParser()
    parser.feed(text)
    parser.close()
    text = html.unescape("".join(parser.parts))
    text = _inline_link_labels(text)
    text = re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])", r"\1", text)
    return text.translate(str.maketrans("", "", "*_~"))


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


def _resolve_repository_path(root: Path, relative: str) -> Path | None:
    try:
        return (root / relative).resolve()
    except (OSError, RuntimeError, ValueError):
        return None


def _validate_mapping_paths(
    values: list[str], field_name: str, location: str, root: Path,
    result: ValidationResult,
) -> None:
    for value in values:
        relative, selector = _mapping_parts(value)
        path = _resolve_repository_path(root, relative)
        if path is None:
            result.error(location, f"{field_name} mapping has invalid path: {relative!r}")
            continue
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
        path = _resolve_repository_path(root, relative)
        if path is None:
            return False
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
    path = _resolve_repository_path(root, source)
    if path is None:
        return False
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
            if not (root / ".git").exists():
                result.error(
                    evidence_loc,
                    "commit evidence requires git metadata to verify reachability and ancestry",
                )
            else:
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
                source_path = _resolve_repository_path(root, source)
                if source_path is None:
                    result.error(evidence_loc, f"evidence source has invalid path: {source!r}")
                    continue
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
    if not base_ref:
        return None
    if not (root / ".git").exists():
        result.error("git", f"base ref {base_ref!r} requires repository git metadata")
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
    if base_commit:
        tree = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", base_commit, "specs"],
            cwd=root, capture_output=True, text=True,
        )
        for relative in tree.stdout.splitlines():
            match = re.match(r"^specs/(SPEC-\d{3})-.*\.md$", relative)
            if not match:
                continue
            text = _git_show(root, base_commit, relative)
            if text is None or not text.startswith(f"# {match.group(1)}"):
                continue
            baseline_legacy[match.group(1)] = Counter(_legacy_normative_lines(text))
            baseline_fingerprints[match.group(1)] = legacy_requirement_fingerprint(text)
        base_conformance_text = _git_show(
            root, base_commit, "specs/CONFORMANCE.json",
        )
        if base_conformance_text is not None:
            try:
                base_conformance = json.loads(
                    base_conformance_text,
                    object_pairs_hook=_unique_json_object,
                )
            except (json.JSONDecodeError, DuplicateJSONKeyError):
                base_conformance = None
            if isinstance(base_conformance, dict):
                base_specs = base_conformance.get("specs")
                for base_record in base_specs if isinstance(base_specs, list) else []:
                    if not isinstance(base_record, dict):
                        continue
                    spec_id = base_record.get("spec_id")
                    fingerprint = base_record.get("legacy_requirement_fingerprint")
                    count = base_record.get("legacy_requirement_count")
                    if (
                        isinstance(spec_id, str)
                        and base_record.get("requirement_id_migration") == "pending"
                        and isinstance(fingerprint, str)
                        and FINGERPRINT_RE.fullmatch(fingerprint)
                        and isinstance(count, int)
                        and not isinstance(count, bool)
                        and count >= 0
                    ):
                        baseline_fingerprints[spec_id] = (fingerprint, count)
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
        path = _resolve_repository_path(root, rel_path)
        if path is None:
            result.error(
                f"specs/CONFORMANCE.json.specs[{index}]",
                f"invalid path: {rel_path!r}",
            )
            continue
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
        visible_contract_text = _visible_inline_text(contract_text)
        for requirement_id in REQUIREMENT_DEFINITION_RE.findall(contract_text):
            definitions.setdefault(requirement_id, []).append(path)
            if requirement_id[:8] != spec_id:
                result.error(str(path.relative_to(root)), f"requirement {requirement_id} must use owning prefix {spec_id}")
        for reference in sorted(set(SPEC_REFERENCE_RE.findall(visible_contract_text))):
            if reference not in canonical:
                result.error(str(path.relative_to(root)), f"broken cross-spec reference {reference}; no canonical spec exists")
        for requirement_reference in sorted(set(REQUIREMENT_REFERENCE_RE.findall(visible_contract_text))):
            requirement_references.setdefault(requirement_reference, []).append(path)
        for target in MARKDOWN_LINK_RE.findall(text):
            target = target.strip().split("#", 1)[0]
            if not target or re.match(r"^(?:https?://|mailto:)", target):
                continue
            linked = _resolve_repository_path(path.parent, target)
            if linked is None:
                result.error(
                    str(path.relative_to(root)),
                    f"Markdown link has invalid path: {target!r}",
                )
                continue
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
