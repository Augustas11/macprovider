#!/usr/bin/env python3
"""Turn the oncall_record workflow input into shell assignments.

GitHub allows 25 workflow_dispatch inputs. The on-call readiness fields share
one JSON object so signed-journey.yml stays under that cap. The workflow's
bash checks are unchanged; this only unpacks the object into the same names.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid

STRING_FIELDS = {
    "launch_environment_id": "LAUNCH_ENV_INPUT",
    "record_version": "RECORD_VERSION_INPUT",
    "primary_operator_contact": "PRIMARY",
    "secondary_operator_contact": "SECONDARY",
    "break_glass_escalation_path": "BREAK_GLASS",
    "compromise_notification_channel": "COMPROMISE",
    "creator_agreement_notification_commitment_ack": "AGREEMENT_ACK",
    "creator_emergency_notification_mechanism": "EMERGENCY",
}

ALIASES = {
    "LAUNCH_ENV_INPUT": "LAUNCH_ENV",
    "RECORD_VERSION_INPUT": "RECORD_VERSION",
}

DEFAULT_TTL = "7776000"
ALLOWED = set(STRING_FIELDS) | {"confirmation_ttl_seconds", "signing_confirmed"}


def fail(message: str) -> None:
    # The runner treats each log line as a workflow command. Keep the
    # annotation on one line and do not echo caller-controlled text.
    safe = message.replace("%", "%25").replace("\r", " ").replace("\n", " ")
    print(f"::error::{safe}", file=sys.stderr)
    raise SystemExit(1)


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    seen: set[str] = set()
    obj: dict[str, object] = {}
    for key, value in pairs:
        if key in seen:
            fail("oncall_record repeats a field")
        seen.add(key)
        obj[key] = value
    return obj


def decode(raw: str) -> dict[str, str]:
    if raw.strip() == "":
        fail("oncall_record is empty")
    try:
        data = json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError:
        fail("oncall_record is not JSON")
    if not isinstance(data, dict):
        fail("oncall_record must be a JSON object")
    unknown = set(data) - ALLOWED
    if unknown:
        fail("oncall_record has unknown fields")

    values: dict[str, str] = {}
    for key, env_name in STRING_FIELDS.items():
        value = data.get(key, "")
        if value is None:
            value = ""
        if not isinstance(value, str):
            fail(f"oncall_record field {key} must be a string")
        if "\n" in value or "\r" in value or "\x00" in value:
            fail(f"oncall_record field {key} must be a single line")
        values[env_name] = value
    for source, dest in ALIASES.items():
        values[dest] = values[source]

    if "confirmation_ttl_seconds" not in data or data["confirmation_ttl_seconds"] is None:
        ttl = DEFAULT_TTL
    else:
        ttl_value = data["confirmation_ttl_seconds"]
        if isinstance(ttl_value, bool) or not isinstance(ttl_value, (int, str)):
            fail("confirmation_ttl_seconds must be an integer or a decimal string")
        if isinstance(ttl_value, int):
            ttl = str(ttl_value)
        else:
            if "\n" in ttl_value or "\r" in ttl_value or "\x00" in ttl_value:
                fail("confirmation_ttl_seconds must be a single line")
            ttl = ttl_value
    values["TTL_INPUT"] = ttl
    values["TTL"] = ttl

    if "signing_confirmed" not in data or data["signing_confirmed"] is None:
        signing = "false"
    else:
        signing_value = data["signing_confirmed"]
        if not isinstance(signing_value, bool):
            fail("signing_confirmed must be a JSON boolean")
        signing = "true" if signing_value else "false"
    values["SIGNING_CONFIRMED_INPUT"] = signing
    return values


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def write_shell(path: str, values: dict[str, str]) -> None:
    text = "".join(f"export {key}={sh_quote(value)}\n" for key, value in values.items())
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, 0o600)


def write_github_env(path: str, values: dict[str, str]) -> None:
    delimiter = "ONCALL_" + uuid.uuid4().hex
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            if delimiter in value:
                fail("oncall_record value cannot be exported")
            handle.write(f"{key}<<{delimiter}\n{value}\n{delimiter}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shell", required=True)
    parser.add_argument("--github-env", required=True)
    parser.add_argument("--json", default=None)
    args = parser.parse_args()
    raw = args.json if args.json is not None else os.environ.get("ONCALL_RECORD", "")
    values = decode(raw)
    write_shell(args.shell, values)
    write_github_env(args.github_env, values)


if __name__ == "__main__":
    main()
