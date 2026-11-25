#!/usr/bin/env python3
"""SPEC-044-R015 model facts: validate model-facts.json and embed it in the CLI.

`phase3-binary/catalog/autotune/model-facts.json` holds, per signed candidate
catalog key, the model's declared context window and the network capabilities
Malibu shows as badges. It is a separate file because the candidate catalog's
row schema is closed in every released CLI: a new row key there would fail
their strict validation.

Each facts row binds to its catalog row by `model_id` and `model_revision`,
so the CLI shows nothing for a row whose served artifact changed. A catalog
row without facts is a warning here, never a failure.

    python3 scripts/model-facts.py check      # validate and compare the Swift copy
    python3 scripts/model-facts.py generate   # rewrite the Swift copy
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FACTS_PATH = ROOT / "phase3-binary/catalog/autotune/model-facts.json"
CANDIDATES_PATH = ROOT / "phase3-binary/catalog/autotune/autotune-candidates.json"
SWIFT_PATH = ROOT / "phase3-binary/Sources/macprovider-cli/ModelFacts.generated.swift"

SCHEMA = "macprovider.model-facts.v1"
CAPABILITIES = ("reasoning", "tools", "vision")
CONTEXT_MIN = 1_024
CONTEXT_MAX = 16_777_216
SOURCE_PATTERN = re.compile(r"^(text_config\.)?[a-z_]+$")
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9._/-]+$")
ROW_KEYS = {"capabilities", "context_length", "context_length_source", "model_id", "model_revision"}


class FactsError(Exception):
    pass


def _reject_duplicates(pairs: list[tuple[str, object]]) -> dict:
    seen: dict = {}
    for key, value in pairs:
        if key in seen:
            raise FactsError(f"duplicate key {key!r}")
        seen[key] = value
    return seen


def load_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_reject_duplicates)


def validate(facts: dict) -> None:
    """The schema. A failure here would make the CLI drop every fact."""
    if set(facts) != {"schema_version", "rows"}:
        raise FactsError("top level must be exactly schema_version and rows")
    if facts["schema_version"] != SCHEMA:
        raise FactsError(f"schema_version must be {SCHEMA}")
    rows = facts["rows"]
    if not isinstance(rows, dict) or not rows:
        raise FactsError("rows must be a non-empty object")
    for key, row in rows.items():
        if not isinstance(row, dict) or set(row) != ROW_KEYS:
            raise FactsError(f"{key}: row keys must be exactly {sorted(ROW_KEYS)}")
        if not IDENTIFIER_PATTERN.fullmatch(key):
            raise FactsError(f"{key!r}: catalog key must match {IDENTIFIER_PATTERN.pattern}")
        if not isinstance(row["model_id"], str) or not IDENTIFIER_PATTERN.fullmatch(row["model_id"]):
            raise FactsError(f"{key}: model_id must match {IDENTIFIER_PATTERN.pattern}")
        if not isinstance(row["model_revision"], str) or not re.fullmatch(r"[0-9a-f]{40}", row["model_revision"]):
            raise FactsError(f"{key}: model_revision must be lowercase 40-hex")
        length = row["context_length"]
        if not isinstance(length, int) or isinstance(length, bool) or not CONTEXT_MIN <= length <= CONTEXT_MAX:
            raise FactsError(f"{key}: context_length must be an integer in [{CONTEXT_MIN}, {CONTEXT_MAX}]")
        source = row["context_length_source"]
        if not isinstance(source, str) or not SOURCE_PATTERN.fullmatch(source):
            raise FactsError(f"{key}: context_length_source must name a config.json field")
        capabilities = row["capabilities"]
        if not isinstance(capabilities, list) or any(c not in CAPABILITIES for c in capabilities):
            raise FactsError(f"{key}: capabilities must be drawn from {list(CAPABILITIES)}")
        if capabilities != sorted(set(capabilities)):
            raise FactsError(f"{key}: capabilities must be sorted and unique")


def binding_warnings(facts: dict, candidates: dict) -> list[str]:
    """Catalog rows the facts do not cover. The CLI shows no facts for them,
    so these are warnings: a catalog change never waits on this file."""
    rows = facts["rows"]
    catalog = candidates["rows"]
    warnings = [f"{key}: catalog row has no facts" for key in sorted(set(catalog) - set(rows))]
    warnings += [f"{key}: facts row is not in the candidate catalog" for key in sorted(set(rows) - set(catalog))]
    for key in sorted(set(rows) & set(catalog)):
        if (rows[key]["model_id"], rows[key]["model_revision"]) != (catalog[key]["model_id"], catalog[key].get("model_revision")):
            warnings.append(f"{key}: model_id or model_revision differs from the candidate catalog")
    return warnings


def swift_source(facts_bytes: bytes) -> str:
    text = facts_bytes.decode("utf-8")
    # The JSON is embedded in a Swift #"""..."""# literal, where \# starts an
    # escape or interpolation and """# ends the literal.
    if '"""#' in text or "\\#" in text or not text.endswith("\n"):
        raise FactsError("facts JSON cannot contain a raw-string terminator or escape and must end with a newline")
    return (
        "// Generated by scripts/model-facts.py from\n"
        "// phase3-binary/catalog/autotune/model-facts.json. DO NOT EDIT.\n"
        "import Foundation\n"
        "\n"
        "extension ModelFacts {\n"
        '    static let bakedJSON = #"""\n'
        f"{text}"
        '"""#\n'
        "}\n"
    )


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in {"check", "generate"}:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        facts_bytes = FACTS_PATH.read_bytes()
        facts = load_json(FACTS_PATH)
        validate(facts)
        for warning in binding_warnings(facts, load_json(CANDIDATES_PATH)):
            print(f"model-facts: warning: {warning}", file=sys.stderr)
        expected = swift_source(facts_bytes)
    except (FactsError, ValueError, KeyError) as error:
        print(f"model-facts: {error}", file=sys.stderr)
        return 1
    if argv[1] == "generate":
        SWIFT_PATH.write_text(expected, encoding="utf-8")
        return 0
    if not SWIFT_PATH.exists() or SWIFT_PATH.read_text(encoding="utf-8") != expected:
        print(f"model-facts: {SWIFT_PATH.relative_to(ROOT)} is stale; run scripts/model-facts.py generate", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
