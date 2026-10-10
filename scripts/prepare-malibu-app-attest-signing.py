#!/usr/bin/env python3
"""Embed the Malibu.app App Attest provisioning profile and derive its entitlements.

Only the Malibu.app main executable (tech.malibu.app) may hold
the App Attest key, and it must carry a Developer ID provisioning profile that
grants com.apple.developer.devicecheck.app-attest-opt-in. The embedded
macprovider-cli keeps no entitlements at all (AMFI kills a naked CLI that
claims restricted entitlements without a profile).

  prepare  validates the profile against the team and the committed base
           entitlements, copies it to Contents/embedded.provisionprofile, and
           writes the exact entitlements the outer codesign must use.
  verify   checks a signed app: embedded profile bytes, and signed
           entitlements equal to the prepared set.

The profile and entitlements are not secret, but this tool never prints
profile bytes or certificate material.
"""

from __future__ import annotations

import argparse
import datetime
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any, NoReturn

BUNDLE_ID = "tech.malibu.app"
APP_ATTEST_KEY = "com.apple.developer.devicecheck.app-attest-opt-in"
APPLICATION_IDENTIFIER_KEYS = ("com.apple.application-identifier", "application-identifier")
TEAM_IDENTIFIER_KEY = "com.apple.developer.team-identifier"
KEYCHAIN_KEY = "keychain-access-groups"
TEAM_PATTERN = re.compile(r"^[A-Z0-9]{10}$")
MAX_PROFILE_BYTES = 256 * 1024
# The committed base may declare only the App Attest opt-in; every other key
# in the signed set is derived from the profile and the team.
BASE_KEYS = {APP_ATTEST_KEY}
FORBIDDEN_KEYS = {
    "com.apple.security.get-task-allow",
    "get-task-allow",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.debugger",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"malibu app attest signing: {message}")


def require_regular_file(path: pathlib.Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlink file")


def require_team(team: str) -> str:
    if not TEAM_PATTERN.fullmatch(team or ""):
        fail("team must be exactly 10 uppercase letters or digits")
    return team


def load_plist(path: pathlib.Path, label: str) -> Any:
    require_regular_file(path, label)
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception:
        fail(f"{label} is not a property list")


def decode_profile(profile: pathlib.Path, decoded: pathlib.Path | None) -> dict[str, Any]:
    """Decodes the CMS-signed profile with `security cms -D`. Tests may pass an
    already-decoded property list instead."""
    if decoded is not None:
        document = load_plist(decoded, "decoded profile")
    else:
        require_regular_file(profile, "provisioning profile")
        try:
            output = subprocess.run(
                ["/usr/bin/security", "cms", "-D", "-i", str(profile)],
                check=True,
                capture_output=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError):
            fail("provisioning profile is not a valid CMS-signed profile")
        try:
            document = plistlib.loads(output)
        except Exception:
            fail("provisioning profile payload is not a property list")
    if not isinstance(document, dict):
        fail("provisioning profile payload must be a dictionary")
    return document


def application_identifier(entitlements: dict[str, Any]) -> str | None:
    for key in APPLICATION_IDENTIFIER_KEYS:
        value = entitlements.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def validate_profile(document: dict[str, Any], team: str, base: dict[str, Any], now: datetime.datetime) -> dict[str, Any]:
    entitlements = document.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail("profile has no Entitlements dictionary")
    app_id = f"{team}.{BUNDLE_ID}"
    if application_identifier(entitlements) != app_id:
        fail(f"profile application identifier must be {app_id}")
    if entitlements.get(TEAM_IDENTIFIER_KEY) != team:
        fail("profile team identifier does not match the signing team")
    teams = document.get("TeamIdentifier")
    if not isinstance(teams, list) or team not in teams:
        fail("profile TeamIdentifier does not contain the signing team")
    if document.get("ProvisionsAllDevices") is not True:
        fail("profile must be a Developer ID profile (ProvisionsAllDevices)")
    expiration = document.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        fail("profile has no ExpirationDate")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= now:
        fail("profile has expired")
    if APP_ATTEST_KEY not in entitlements:
        fail(f"profile does not grant {APP_ATTEST_KEY}")
    if entitlements[APP_ATTEST_KEY] != base[APP_ATTEST_KEY]:
        fail(f"profile {APP_ATTEST_KEY} differs from the committed base entitlements")
    for key in FORBIDDEN_KEYS:
        if entitlements.get(key) not in (None, False):
            fail(f"profile grants forbidden entitlement {key}")
    return entitlements


def keychain_group(profile_entitlements: dict[str, Any], team: str) -> list[str] | None:
    """The profile grants keychain groups, often as a team wildcard; the signed
    app names exactly its own App ID group inside that grant."""
    groups = profile_entitlements.get(KEYCHAIN_KEY)
    if groups is None:
        return None
    if not isinstance(groups, list) or not all(isinstance(group, str) for group in groups):
        fail("profile keychain-access-groups is malformed")
    app_group = f"{team}.{BUNDLE_ID}"
    if app_group in groups or f"{team}.*" in groups:
        return [app_group]
    fail("profile keychain-access-groups does not cover the app group")


def load_base(path: pathlib.Path) -> dict[str, Any]:
    base = load_plist(path, "base entitlements")
    if not isinstance(base, dict) or set(base) != BASE_KEYS:
        fail(f"base entitlements must declare exactly {sorted(BASE_KEYS)}")
    value = base[APP_ATTEST_KEY]
    if not (isinstance(value, list) and value and all(isinstance(item, str) and item for item in value)) and not (
        isinstance(value, str) and value
    ):
        fail(f"base {APP_ATTEST_KEY} must be a non-empty string or array of strings")
    return base


def signing_entitlements(base: dict[str, Any], profile_entitlements: dict[str, Any], team: str) -> dict[str, Any]:
    app_id = f"{team}.{BUNDLE_ID}"
    result: dict[str, Any] = {
        APP_ATTEST_KEY: base[APP_ATTEST_KEY],
        "com.apple.application-identifier": app_id,
        TEAM_IDENTIFIER_KEY: team,
    }
    group = keychain_group(profile_entitlements, team)
    if group is not None:
        result[KEYCHAIN_KEY] = group
    return result


def require_app(app: pathlib.Path) -> pathlib.Path:
    try:
        metadata = app.lstat()
    except FileNotFoundError:
        fail("Malibu.app is missing")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail("Malibu.app must be a non-symlink directory")
    contents = app / "Contents"
    try:
        contents_metadata = contents.lstat()
    except FileNotFoundError:
        fail("Malibu.app Contents is missing")
    if stat.S_ISLNK(contents_metadata.st_mode) or not stat.S_ISDIR(contents_metadata.st_mode):
        fail("Malibu.app Contents must be a non-symlink directory")
    return contents


def prepare(args: argparse.Namespace) -> None:
    team = require_team(args.team)
    base = load_base(pathlib.Path(args.base))
    profile_path = pathlib.Path(args.profile)
    require_regular_file(profile_path, "provisioning profile")
    if profile_path.stat().st_size > MAX_PROFILE_BYTES:
        fail("provisioning profile is too large")
    document = decode_profile(profile_path, pathlib.Path(args.decoded_profile) if args.decoded_profile else None)
    profile_entitlements = validate_profile(document, team, base, datetime.datetime.now(datetime.timezone.utc))
    entitlements = signing_entitlements(base, profile_entitlements, team)

    contents = require_app(pathlib.Path(args.app))
    embedded = contents / "embedded.provisionprofile"
    if embedded.is_symlink() or (embedded.exists() and not embedded.is_file()):
        fail("existing embedded.provisionprofile is not a regular file")
    with tempfile.NamedTemporaryFile(dir=contents, prefix=".embedded.", delete=False) as temporary:
        temporary_path = pathlib.Path(temporary.name)
        with profile_path.open("rb") as source:
            shutil.copyfileobj(source, temporary)
    os.chmod(temporary_path, 0o644)
    os.replace(temporary_path, embedded)

    out = pathlib.Path(args.out)
    if out.is_symlink():
        fail("output entitlements path must not be a symlink")
    with out.open("wb") as handle:
        plistlib.dump(entitlements, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    print(f"malibu app attest signing: prepared {len(entitlements)} entitlements for {team}.{BUNDLE_ID}")


def signed_entitlements(app: pathlib.Path, override: pathlib.Path | None) -> dict[str, Any]:
    if override is not None:
        document = load_plist(override, "signed entitlements")
    else:
        try:
            output = subprocess.run(
                ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)],
                check=True,
                capture_output=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError):
            fail("could not read the signed Malibu.app entitlements")
        try:
            document = plistlib.loads(output)
        except Exception:
            fail("signed Malibu.app entitlements are not a property list")
    if not isinstance(document, dict):
        fail("signed Malibu.app entitlements must be a dictionary")
    return document


def verify(args: argparse.Namespace) -> None:
    require_team(args.team)
    expected = load_plist(pathlib.Path(args.entitlements), "prepared entitlements")
    if not isinstance(expected, dict) or APP_ATTEST_KEY not in expected:
        fail("prepared entitlements do not grant App Attest")
    app = pathlib.Path(args.app)
    contents = require_app(app)
    embedded = contents / "embedded.provisionprofile"
    require_regular_file(embedded, "embedded.provisionprofile")
    if args.profile:
        profile = pathlib.Path(args.profile)
        require_regular_file(profile, "provisioning profile")
        if embedded.read_bytes() != profile.read_bytes():
            fail("embedded.provisionprofile differs from the release profile")
    actual = signed_entitlements(app, pathlib.Path(args.signed_entitlements) if args.signed_entitlements else None)
    if actual != expected:
        fail("signed Malibu.app entitlements differ from the prepared App Attest set")
    if expected.get("com.apple.application-identifier") != f"{args.team}.{BUNDLE_ID}":
        fail("signed Malibu.app application identifier is not the release App ID")
    print("malibu app attest signing: verified signed entitlements and embedded profile")


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--profile", required=True)
    p.add_argument("--team", required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--app", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--decoded-profile", help=argparse.SUPPRESS)
    v = sub.add_parser("verify")
    v.add_argument("--app", required=True)
    v.add_argument("--team", required=True)
    v.add_argument("--entitlements", required=True)
    v.add_argument("--profile")
    v.add_argument("--signed-entitlements", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.command == "prepare":
        prepare(args)
    else:
        verify(args)


if __name__ == "__main__":
    main(sys.argv[1:])
