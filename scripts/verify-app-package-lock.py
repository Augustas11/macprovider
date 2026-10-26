#!/usr/bin/env python3
"""Build-free allowlist for Malibu's sole reviewed non-updater dependency."""
import json
import pathlib
import re
import subprocess
import sys

URL = "https://github.com/migueldeicaza/SwiftTerm"
VERSION = "1.2.5"
REVISION = "e2b431dbf73f775fb4807a33e4572ffd3dc6933a"


def verify(app, resolved=None):
    project = (app / "project.yml").read_text()
    blocks = re.findall(r"^packages:[^\n]*\n((?:[ \t]+[^\n]*\n|\n)*)", project, re.M)
    expected = f"  SwiftTerm:\n    url: {URL}\n    exactVersion: {VERSION}"
    if len(blocks) != 1 or blocks[0].strip("\n") != expected:
        raise ValueError("Malibu permits only the reviewed exact SwiftTerm package")
    if any(value in project for value in ("Sparkle", "SUFeedURL", "SUPublicEDKey", "plugin")):
        raise ValueError("Malibu may not add updater dependencies or build plugins")
    if re.findall(r"^\s*- package: (.+)$", project, re.M) != ["SwiftTerm"]:
        raise ValueError("Malibu must link only SwiftTerm")
    lock = json.loads((resolved or app / "Package.resolved").read_text())
    if lock.get("version") not in (2, 3) or lock.get("pins") != [{
        "identity": "swiftterm", "kind": "remoteSourceControl", "location": URL,
        "state": {"revision": REVISION, "version": VERSION},
    }]:
        raise ValueError("Malibu resolution must contain only reviewed SwiftTerm version and revision")


if __name__ == "__main__":
    try:
        app = pathlib.Path(sys.argv[1])
        verify(app)
        if len(sys.argv) > 2:
            verify(app, pathlib.Path(sys.argv[2]))
        if len(sys.argv) > 3:
            checkouts = pathlib.Path(sys.argv[3]) / "checkouts"
            entries = list(checkouts.iterdir())
            if len(entries) != 1 or entries[0].name.lower() != "swiftterm":
                raise ValueError("Malibu may not resolve transitive packages")
            package = entries[0]
            revision = subprocess.check_output(["git", "-C", str(package), "rev-parse", "HEAD"], text=True).strip()
            if revision != REVISION:
                raise ValueError("resolved SwiftTerm checkout differs from reviewed revision")
            if subprocess.check_output(["git", "-C", str(package), "status", "--porcelain"], text=True).strip():
                raise ValueError("resolved SwiftTerm checkout has unreviewed modifications")
            # The immutable reviewed revision has no plugin declarations. Deny
            # them explicitly before any test/archive can execute package code.
            if re.search(r"\bplugins?\b", (package / "Package.swift").read_text()):
                raise ValueError("Malibu may not execute package plugins")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
