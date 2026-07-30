#!/usr/bin/env python3
import argparse
import json
import pathlib
import re


def fail(message: str) -> None:
    raise SystemExit(f"verify-release-draft-identity: {message}")


parser = argparse.ArgumentParser(
    description="Bind a GitHub draft lookup to the reviewed tag and commit."
)
parser.add_argument("mode", choices=("cli", "api"))
parser.add_argument("release_json")
parser.add_argument("tag")
parser.add_argument("commit")
parser.add_argument("--release-id", type=int)
args = parser.parse_args()

if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
    fail("invalid tag")
if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
    fail("invalid commit")
if args.release_id is not None and args.release_id <= 0:
    fail("invalid expected release id")

release = json.loads(pathlib.Path(args.release_json).read_text(encoding="utf-8"))
if not isinstance(release, dict):
    fail("release lookup is not an object")

if args.mode == "cli":
    release_id = release.get("databaseId")
    valid = (
        type(release_id) is int
        and release_id > 0
        and release.get("isDraft") is True
        and release.get("tagName") == args.tag
        and release.get("targetCommitish") == args.commit
    )
else:
    release_id = release.get("id")
    valid = (
        type(release_id) is int
        and release_id > 0
        and release.get("draft") is True
        and release.get("immutable") is not True
        and release.get("tag_name") == args.tag
        and release.get("target_commitish") == args.commit
    )

if args.release_id is not None:
    valid = valid and release_id == args.release_id
if not valid:
    fail(f"{args.mode} lookup did not return the expected draft identity")

print(release_id)
