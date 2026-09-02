#!/usr/bin/env python3
"""Validate the hosted MacProvider agent onboarding skill source."""

from __future__ import annotations

import hashlib
import json
import re
import sys
import tempfile
import argparse
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
SKILL_PATH = ROOT / "docs" / "agent-onboarding" / "SKILL.md"
INDEX_PATH = ROOT / "docs" / "agent-onboarding" / ".well-known" / "skills" / "index.json"

CANONICAL_SKILL_URL = "https://get.malibu.tech/skill.md"
CANONICAL_INDEX_URL = "https://get.malibu.tech/.well-known/skills/index.json"

REQUIRED_REFERENCES = [
    "README.md",
    "docs/using-macprovider-with-openai-sdk.md",
    "docs/runbooks/provider-cli-release-verification.md",
    "ops/runbooks/entry-610-first-hop-recovery.md",
    "specs/SPEC-003-open-onboarding.md",
    "specs/SPEC-006-buyer-api.md",
    "specs/SPEC-020-provider-autoupdate.md",
    "specs/SPEC-035-provider-connection-diagnostics.md",
]

REQUIRED_SKILL_SNIPPETS = [
    CANONICAL_SKILL_URL,
    CANONICAL_INDEX_URL,
    "https://get.malibu.tech/install.sh",
    "https://get.malibu.tech/uninstall.sh",
    "https://api.malibu.tech/v1",
    'tmp_install="$(mktemp "${TMPDIR:-/tmp}/macprovider-install.XXXXXX")',
    "--remove-on-error https://get.malibu.tech/install.sh",
    'bash "$tmp_install"',
    "malibu-cli status --json",
    "malibu-cli status --advanced",
    "malibu-cli update --check",
    "--remove-on-error https://get.malibu.tech/uninstall.sh",
    'uninstall_sha="$(shasum -a 256 "$tmp_uninstall"',
    'bash "$tmp_uninstall" --dry-run',
    "shasum -a 256 -c -",
    'bash "$tmp_uninstall"',
    "base_url=\"https://api.malibu.tech/v1\"",
    "baseURL: \"https://api.malibu.tech/v1\"",
]

REQUIRED_GUARDRAILS = [
    "never print secrets",
    "non-production local smoke",
    "explicit operator approval",
    "do not run destructive commands",
    "do not inspect `d-inference` source",
    "do not introduce legacy `streamvc.live` urls",
]

FORBIDDEN_LITERAL_SNIPPETS = [
    "sk-",
    "ghp_",
    "BEGIN PRIVATE KEY",
    "bash <(",
    "$(curl",
    "`curl",
    "bash -c",
]

FORBIDDEN_PATTERNS = [
    re.compile(r"\|\s*(?:/usr/bin/env\s+)?(?:/bin/)?(?:bash|sh|zsh)(?:\s|$)"),
]

ALLOWED_URLS = {
    "https://get.malibu.tech/skill.md",
    "https://get.malibu.tech/.well-known/skills/index.json",
    "https://get.malibu.tech/.well-known/skills/index.v1",
    "https://get.malibu.tech/install.sh",
    "https://get.malibu.tech/uninstall.sh",
    "https://api.malibu.tech/v1",
    "https://api.malibu.tech/auth/github/start",
}
URI_RE = re.compile(r"(?:\b[A-Za-z][A-Za-z0-9+.-]*:[^\s`<>\")]+|//[^\s`<>\")]+)")
SUPPRESS_FAILURE_OUTPUT = False


def fail(message: str) -> None:
    if not SUPPRESS_FAILURE_OUTPUT:
        print(f"verify-agent-onboarding-skill: ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing {display_path(path)}")
    except UnicodeDecodeError as exc:
        fail(f"{display_path(path)} is not valid UTF-8: {exc}")


def validate_urls(text: str) -> None:
    for match in URI_RE.finditer(text):
        raw = match.group(0).rstrip("`').,")
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:-", raw):
            continue
        require(not raw.startswith("//"), f"protocol-relative URL forbidden: {raw}")
        parsed = urlparse(raw)
        require(parsed.scheme, f"URL scheme missing: {raw}")
        host = (parsed.hostname or "").lower()
        require(parsed.scheme.lower() == "https", f"URL must use https: {raw}")
        require(parsed.username is None and parsed.password is None, f"URL must not contain userinfo: {raw}")
        try:
            port = parsed.port
        except ValueError:
            fail(f"URL has an invalid port: {raw}")
        require(port is None, f"URL must not contain an explicit port: {raw}")
        require(not parsed.params and not parsed.query and not parsed.fragment, f"URL must be canonical without params/query/fragment: {raw}")
        require(not (host == "streamvc.live" or host.endswith(".streamvc.live")), f"legacy host forbidden: {raw}")
        normalized = f"{parsed.scheme.lower()}://{host}{parsed.path}"
        require(normalized in ALLOWED_URLS, f"URL is not allowlisted: {raw}")


def validate_frontmatter(skill: str) -> None:
    lines = skill.splitlines()
    require(lines and lines[0] == "---", "SKILL.md missing YAML front matter")
    closing_index = None
    for index, line in enumerate(lines[1:], start=1):
        if line == "---":
            closing_index = index
            break
    require(closing_index is not None, "SKILL.md front matter is not closed")

    metadata: dict[str, str] = {}
    for line in lines[1:closing_index]:
        if not line.strip():
            continue
        require(":" in line, f"front matter line is not key/value: {line}")
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        require(key, f"front matter key is empty: {line}")
        require(value, f"front matter value is empty: {key}")
        metadata[key] = value

    name = metadata.get("name", "")
    description = metadata.get("description", "")
    require(name == "macprovider-agent-onboarding", "front matter name drifted")
    require(
        re.fullmatch(r"[a-z0-9-]{1,64}", name) is not None,
        "front matter name must be lowercase letters, digits, and hyphens",
    )
    require(description, "front matter description missing")
    require("MacProvider" in description, "front matter description must mention MacProvider")
    require(
        "install" in description.lower() and "OpenAI-compatible SDKs" in description,
        "front matter description must cover provider install and buyer SDK use cases",
    )


def validate_files(
    skill_path: Path = SKILL_PATH,
    index_path: Path = INDEX_PATH,
    *,
    require_reference_paths: bool = True,
) -> str:
    skill_bytes = skill_path.read_bytes() if skill_path.exists() else b""
    require(skill_bytes, f"missing {display_path(skill_path)}")
    require(len(skill_bytes) <= 20_000, "SKILL.md must stay compact for agent ingestion")
    skill = read_text(skill_path)
    index_text = read_text(index_path)
    validate_frontmatter(skill)

    combined = f"{skill}\n{index_text}"
    for forbidden in FORBIDDEN_LITERAL_SNIPPETS:
        require(forbidden not in combined, f"forbidden snippet present: {forbidden}")
    for pattern in FORBIDDEN_PATTERNS:
        require(not pattern.search(combined), f"forbidden pattern present: {pattern.pattern}")
    validate_urls(combined)

    for snippet in REQUIRED_SKILL_SNIPPETS:
        require(snippet in skill, f"SKILL.md missing required snippet: {snippet}")

    lower_skill = skill.lower()
    for snippet in REQUIRED_GUARDRAILS:
        require(snippet in lower_skill, f"SKILL.md missing guardrail phrase: {snippet}")

    for rel in REQUIRED_REFERENCES:
        require(rel in skill, f"SKILL.md missing reference: {rel}")
        if require_reference_paths:
            require((ROOT / rel).exists(), f"referenced path does not exist: {rel}")

    try:
        index = json.loads(index_text)
    except json.JSONDecodeError as exc:
        fail(f"index JSON is invalid: {exc}")

    require(
        index.get("schema_version") == "https://get.malibu.tech/.well-known/skills/index.v1",
        "index schema_version drifted",
    )
    skills = index.get("skills")
    require(isinstance(skills, list) and len(skills) == 1, "index must contain exactly one skill")
    entry = skills[0]
    require(isinstance(entry, dict), "index skill entry must be an object")
    require(entry.get("id") == "macprovider-agent-onboarding", "index skill id drifted")
    require(entry.get("url") == CANONICAL_SKILL_URL, "index skill URL drifted")
    require(entry.get("source_path") == "docs/agent-onboarding/SKILL.md", "index source path drifted")
    require(
        entry.get("content_type") == "text/markdown; charset=utf-8",
        "index content_type drifted",
    )

    digest = hashlib.sha256(skill_bytes).hexdigest()
    require(entry.get("sha256") == digest, "index sha256 does not match SKILL.md")
    return digest


def run_negative_tests() -> None:
    global SUPPRESS_FAILURE_OUTPUT
    with tempfile.TemporaryDirectory(prefix="agent-skill-negative.") as raw:
        temp = Path(raw)
        skill = temp / "SKILL.md"
        index = temp / "index.json"
        skill.write_text(SKILL_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        index.write_text(INDEX_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        source_skill = SKILL_PATH.read_text(encoding="utf-8")
        without_manifest = re.sub(r"\A---\n.*?\n---\n\n?", "", source_skill, count=1, flags=re.S)
        skill.write_text(without_manifest, encoding="utf-8")
        index_payload = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
        index_payload["skills"][0]["sha256"] = hashlib.sha256(without_manifest.encode()).hexdigest()
        index.write_text(json.dumps(index_payload, indent=2) + "\n", encoding="utf-8")
        SUPPRESS_FAILURE_OUTPUT = True
        try:
            validate_files(skill, index)
        except SystemExit as exc:
            SUPPRESS_FAILURE_OUTPUT = False
            require(exc.code == 1, f"negative test missing_manifest exited unexpectedly: {exc.code}")
        else:
            SUPPRESS_FAILURE_OUTPUT = False
            fail("negative test did not fail: missing_manifest")

        mutations = {
            "legacy_http": "\nhttps://streamvc.live/install.sh\n",
            "legacy_mixed_case": "\nhttps://Get.StreamVC.Live/skill.md\n",
            "unexpected_host": "\nhttps://evil.example/install.sh\n",
            "uppercase_scheme_unexpected_host": "\nHTTPS://evil.example/install.sh\n",
            "ssh_legacy_host": "\nssh://streamvc.live/root\n",
            "ftp_unexpected_host": "\nftp://evil.example/install.sh\n",
            "protocol_relative_host": "\n//evil.example/install.sh\n",
            "explicit_port": "\nhttps://get.malibu.tech:444/skill.md\n",
            "userinfo": "\nhttps://user:pass@get.malibu.tech/install.sh\n",
            "query": "\nhttps://get.malibu.tech/skill.md?x=1\n",
            "fragment": "\nhttps://get.malibu.tech/skill.md#install\n",
            "pipe_bash": "\ncurl -fsSL https://get.malibu.tech/install.sh | bash\n",
            "pipe_bash_spaces": "\ncurl -fsSL https://get.malibu.tech/install.sh |  bash\n",
            "pipe_bash_tab": "\ncurl -fsSL https://get.malibu.tech/install.sh |\tbash\n",
            "pipe_bin_bash": "\ncurl -fsSL https://get.malibu.tech/install.sh | /bin/bash\n",
            "pipe_env_bash": "\ncurl -fsSL https://get.malibu.tech/install.sh | /usr/bin/env bash\n",
            "pipe_sh": "\ncurl -fsSL https://get.malibu.tech/install.sh | sh\n",
            "bash_c_curl": "\nbash -c \"$(curl -fsSL https://get.malibu.tech/install.sh)\"\n",
            "process_substitution": "\nbash <(curl -fsSL https://get.malibu.tech/uninstall.sh)\n",
        }
        for name, addition in mutations.items():
            mutated = SKILL_PATH.read_text(encoding="utf-8") + addition
            skill.write_text(mutated, encoding="utf-8")
            index_payload = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
            index_payload["skills"][0]["sha256"] = hashlib.sha256(mutated.encode()).hexdigest()
            index.write_text(json.dumps(index_payload, indent=2) + "\n", encoding="utf-8")
            SUPPRESS_FAILURE_OUTPUT = True
            try:
                validate_files(skill, index)
            except SystemExit as exc:
                SUPPRESS_FAILURE_OUTPUT = False
                require(exc.code == 1, f"negative test {name} exited unexpectedly: {exc.code}")
            else:
                SUPPRESS_FAILURE_OUTPUT = False
                fail(f"negative test did not fail: {name}")

        mixed_case_canonical = SKILL_PATH.read_text(encoding="utf-8") + (
            "\nHTTPS://GET.MALIBU.TECH/skill.md\n"
        )
        skill.write_text(mixed_case_canonical, encoding="utf-8")
        index_payload = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
        index_payload["skills"][0]["sha256"] = hashlib.sha256(
            mixed_case_canonical.encode()
        ).hexdigest()
        index.write_text(json.dumps(index_payload, indent=2) + "\n", encoding="utf-8")
        validate_files(skill, index)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skill", type=Path, default=SKILL_PATH)
    parser.add_argument("--index", type=Path, default=INDEX_PATH)
    parser.add_argument("--no-reference-existence", action="store_true")
    parser.add_argument("--self-test-negatives", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    digest = validate_files(
        args.skill,
        args.index,
        require_reference_paths=not args.no_reference_existence,
    )
    if args.self_test_negatives:
        run_negative_tests()
    print(
        "verify-agent-onboarding-skill: ok "
        f"skill={display_path(args.skill)} "
        f"index={display_path(args.index)} "
        f"sha256={digest}"
    )


if __name__ == "__main__":
    main()
