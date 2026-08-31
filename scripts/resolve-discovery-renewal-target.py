#!/usr/bin/env python3
"""Resolve the renewal target from the CURRENT signed discovery head.

The discovery-head renewal keeps the *current* self-heal head fresh; it never
advances the target (advancing is the coordinator-gated rollout workflow). The
target it must re-sign is therefore whatever the current live transport already
points at -- NOT whatever GitHub currently marks "latest", which legitimately
runs ahead of the signed head until an operator rolls the coordinator forward.

This reads the current signed head JSON and prints the exact target it is bound
to, so the renewal fetches THAT release's compatibility manifests and re-signs
the same target with a fresh sequence and expiry. It never trusts the head's
signature (the caller re-verifies that against the pinned public key); it only
parses the self-declared target identity so the renewal cannot silently drift
onto a different release than the head it is renewing.

Usage:
  resolve-discovery-renewal-target.py CURRENT_HEAD_JSON REPOSITORY
Prints: "<tag> <commit>" for a well-formed head bound to REPOSITORY.
Exit 1 (fail closed) for any malformed, missing, or off-repository target.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"resolve-discovery-renewal-target: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_duplicates(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            fail(f"current head contains duplicate key {key!r}")
        result[key] = value
    return result


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        fail("usage: resolve-discovery-renewal-target.py CURRENT_HEAD_JSON REPOSITORY")
    head_path, repository = argv
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        fail("repository is invalid")
    path = pathlib.Path(head_path)
    if not path.is_file() or path.is_symlink():
        fail(f"current head is absent or unsafe: {path}")
    try:
        envelope = json.loads(path.read_bytes().decode("utf-8"), object_pairs_hook=reject_duplicates)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"current head is invalid: {exc}")
    if not isinstance(envelope, dict):
        fail("current head must be an object")
    signed = envelope.get("signed")
    if not isinstance(signed, dict):
        fail("current head has no signed object")
    set_id = signed.get("target_compatibility_set_id")
    if not isinstance(set_id, str):
        fail("current head has no target_compatibility_set_id")
    match = re.fullmatch(
        r"(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+):(?P<tag>v[0-9]+\.[0-9]+\.[0-9]+)@(?P<commit>[0-9a-f]{40})",
        set_id,
    )
    if match is None:
        fail("current head target_compatibility_set_id is malformed")
    if match.group("repo") != repository:
        fail("current head target is bound to a different repository")
    print(match.group("tag"), match.group("commit"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
