"""Malibu.app App Attest profile embedding and entitlements."""

from __future__ import annotations

import datetime
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/prepare-malibu-app-attest-signing.py"
BASE = ROOT / "phase3-binary/app/Malibu.entitlements"
TEAM = "AB12CD34EF"
APP_ATTEST = "com.apple.developer.devicecheck.app-attest-opt-in"


def profile_document(**overrides: object) -> dict[str, object]:
    with BASE.open("rb") as handle:
        base = plistlib.load(handle)
    entitlements: dict[str, object] = {
        "com.apple.application-identifier": f"{TEAM}.tech.malibu.app",
        "com.apple.developer.team-identifier": TEAM,
        "keychain-access-groups": [f"{TEAM}.*"],
        APP_ATTEST: base[APP_ATTEST],
    }
    document: dict[str, object] = {
        "Entitlements": entitlements,
        "TeamIdentifier": [TEAM],
        "ProvisionsAllDevices": True,
        "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=30),
    }
    for key, value in overrides.items():
        if key.startswith("ent:"):
            name = key[4:]
            if value is None:
                entitlements.pop(name, None)
            else:
                entitlements[name] = value
        elif value is None:
            document.pop(key, None)
        else:
            document[key] = value
    return document


class MalibuAppAttestSigningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root / "Malibu.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.profile = self.root / "profile.provisionprofile"
        self.profile.write_bytes(b"cms-profile-bytes")
        self.decoded = self.root / "decoded.plist"
        self.out = self.root / "Malibu-release.entitlements"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)

    def prepare(self, document: dict[str, object], team: str = TEAM) -> subprocess.CompletedProcess[str]:
        with self.decoded.open("wb") as handle:
            plistlib.dump(document, handle)
        return self.run_script(
            "prepare", "--profile", str(self.profile), "--team", team, "--base", str(BASE),
            "--app", str(self.app), "--out", str(self.out), "--decoded-profile", str(self.decoded),
        )

    def test_prepare_embeds_profile_and_derives_exact_entitlements(self) -> None:
        result = self.prepare(profile_document())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Contents/embedded.provisionprofile").read_bytes(), b"cms-profile-bytes")
        with self.out.open("rb") as handle:
            entitlements = plistlib.load(handle)
        with BASE.open("rb") as handle:
            base = plistlib.load(handle)
        self.assertEqual(entitlements, {
            APP_ATTEST: base[APP_ATTEST],
            "com.apple.application-identifier": f"{TEAM}.tech.malibu.app",
            "com.apple.developer.team-identifier": TEAM,
            "keychain-access-groups": [f"{TEAM}.tech.malibu.app"],
        })
        verified = self.run_script(
            "verify", "--app", str(self.app), "--team", TEAM, "--entitlements", str(self.out),
            "--profile", str(self.profile), "--signed-entitlements", str(self.out),
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_prepare_rejects_profiles_that_do_not_match(self) -> None:
        expired = datetime.datetime(2020, 1, 1)
        cases = {
            "wrong app id": profile_document(**{"ent:com.apple.application-identifier": f"{TEAM}.tech.malibu.other"}),
            "wrong team": profile_document(**{"ent:com.apple.developer.team-identifier": "ZZ99ZZ99ZZ"}),
            "team list": profile_document(TeamIdentifier=["ZZ99ZZ99ZZ"]),
            "not developer id": profile_document(ProvisionsAllDevices=None),
            "expired": profile_document(ExpirationDate=expired),
            "no app attest": profile_document(**{f"ent:{APP_ATTEST}": None}),
            "different app attest value": profile_document(**{f"ent:{APP_ATTEST}": ["other"]}),
            "get-task-allow": profile_document(**{"ent:com.apple.security.get-task-allow": True}),
            "foreign keychain group": profile_document(**{"ent:keychain-access-groups": ["ZZ99ZZ99ZZ.*"]}),
        }
        for name, document in cases.items():
            with self.subTest(name):
                result = self.prepare(document)
                self.assertNotEqual(result.returncode, 0, name)
                self.assertIn("malibu app attest signing", result.stderr)
        self.assertNotEqual(self.prepare(profile_document(), team="ab12cd34ef").returncode, 0)

    def test_verify_rejects_drift(self) -> None:
        self.assertEqual(self.prepare(profile_document()).returncode, 0)
        drifted = self.root / "drifted.plist"
        with self.out.open("rb") as handle:
            entitlements = plistlib.load(handle)
        entitlements["com.apple.security.get-task-allow"] = True
        with drifted.open("wb") as handle:
            plistlib.dump(entitlements, handle)
        result = self.run_script(
            "verify", "--app", str(self.app), "--team", TEAM, "--entitlements", str(self.out),
            "--signed-entitlements", str(drifted),
        )
        self.assertNotEqual(result.returncode, 0)
        other_profile = self.root / "other.provisionprofile"
        other_profile.write_bytes(b"different")
        result = self.run_script(
            "verify", "--app", str(self.app), "--team", TEAM, "--entitlements", str(self.out),
            "--profile", str(other_profile), "--signed-entitlements", str(self.out),
        )
        self.assertNotEqual(result.returncode, 0)

    def test_committed_entitlement_files(self) -> None:
        with BASE.open("rb") as handle:
            base = plistlib.load(handle)
        self.assertEqual(set(base), {APP_ATTEST})
        with (ROOT / "phase3-binary/app/MalibuLocal.entitlements").open("rb") as handle:
            self.assertEqual(plistlib.load(handle), {})


if __name__ == "__main__":
    unittest.main()
