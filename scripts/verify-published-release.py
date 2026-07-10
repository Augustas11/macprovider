#!/usr/bin/env python3
import json
import pathlib
import sys


def fail(message: str) -> None:
    raise SystemExit(f"verify-published-release: {message}")


if len(sys.argv) != 6:
    fail("usage: RELEASE_ID PRERELEASE RELEASE_BY_ID RELEASE_BY_TAG LATEST_RELEASE")

release_id_raw, prerelease_raw, by_id_path, by_tag_path, latest_path = sys.argv[1:]
if not release_id_raw.isdigit() or int(release_id_raw) <= 0:
    fail("release id is invalid")
if prerelease_raw not in {"true", "false"}:
    fail("prerelease state is invalid")
release_id = int(release_id_raw)
expected_prerelease = prerelease_raw == "true"

by_id = json.loads(pathlib.Path(by_id_path).read_text(encoding="utf-8"))
by_tag = json.loads(pathlib.Path(by_tag_path).read_text(encoding="utf-8"))
latest = json.loads(pathlib.Path(latest_path).read_text(encoding="utf-8"))
for label, release in (("numeric", by_id), ("tag", by_tag)):
    if release.get("id") != release_id:
        fail(f"{label} release lookup differs from the captured numeric id")
    if release.get("draft") is not False or release.get("immutable") is not True:
        fail(f"{label} release is not public and immutable")
    if release.get("prerelease") is not expected_prerelease:
        fail(f"{label} release prerelease state differs from validated input")

latest_id = latest.get("id")
if expected_prerelease:
    if latest_id == release_id:
        fail("prerelease unexpectedly resolves through the stable latest endpoint")
elif latest_id != release_id:
    fail("stable latest endpoint does not resolve to the captured numeric release")
