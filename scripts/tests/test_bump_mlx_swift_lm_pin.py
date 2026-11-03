"""scripts/bump-mlx-swift-lm-pin.py against a temp copy of the pin sites."""

import contextlib
import importlib.util
import io
import json
import pathlib
import re
import shutil
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC_ = importlib.util.spec_from_file_location("bump_mlx_swift_lm_pin", ROOT / "scripts/bump-mlx-swift-lm-pin.py")
bump = importlib.util.module_from_spec(SPEC_)
SPEC_.loader.exec_module(bump)

SITES = [bump.PACKAGE_SWIFT, bump.PACKAGE_RESOLVED, bump.KV_ADAPTER, bump.PINS, bump.WATCH_TEST,
         bump.MATRIX, bump.SPEC, bump.CONFORMANCE]
NEW_TAG = "9.9.9-macprovider.1"
NEW_REV = "0123456789abcdef0123456789abcdef01234567"


def current_pin():
    text = (ROOT / bump.PINS).read_text()
    tag = re.search(r'^SPEC048_MLX_SWIFT_LM_TAG = "([^"]+)"$', text, re.M).group(1)
    rev = re.search(r'^SPEC048_MLX_SWIFT_LM_REVISION = "([0-9a-f]{40})"$', text, re.M).group(1)
    version = (ROOT / bump.SPEC).read_text().split("\n")[2].split()[-1]
    return tag, rev, version


class BumpPinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        for site in SITES:
            (self.root / site).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / site, self.root / site)
        self.old_tag, self.old_rev, self.old_version = current_pin()
        major, minor, patch = self.old_version.split(".")
        self.new_version = f"{major}.{minor}.{int(patch) + 1}"

    def tearDown(self):
        self.tmp.cleanup()

    def run_bump(self, *extra, tag=NEW_TAG, rev=NEW_REV):
        argv = ["--tag", tag, "--revision", rev, "--summary", "Test the pin move",
                "--issue", "2210", "--date", "2026-11-02", "--root", str(self.root), *extra]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                rc = bump.main(argv)
            except SystemExit as exit_:
                rc = exit_.code
        return rc, out.getvalue(), err.getvalue()

    def read(self, site):
        return (self.root / site).read_text()

    def snapshot(self):
        return {site: self.read(site) for site in SITES}

    def test_moves_every_site(self):
        rc, out, err = self.run_bump("--skip-regenerate")
        self.assertEqual(rc, 0, err)
        for site in (bump.PACKAGE_SWIFT, bump.PACKAGE_RESOLVED, bump.KV_ADAPTER, bump.PINS,
                     bump.WATCH_TEST, bump.MATRIX, bump.SPEC):
            self.assertIn(NEW_REV, self.read(site), site)
        # The old revision survives only as prior-tuple history in the spec,
        # and nowhere in the machine sites.
        for site in (bump.PACKAGE_SWIFT, bump.PACKAGE_RESOLVED, bump.KV_ADAPTER, bump.PINS, bump.WATCH_TEST):
            self.assertNotIn(self.old_rev, self.read(site), site)
        pins = self.read(bump.PINS)
        self.assertIn(f'SPEC048_MLX_SWIFT_LM_TAG = "{NEW_TAG}"', pins)
        self.assertIn(f'SPEC048_MLX_SWIFT_LM_REVISION = "{NEW_REV}"', pins)
        self.assertIn(f"// Tag {NEW_TAG} (#2210) on {self.old_tag}: Test", self.read(bump.PACKAGE_SWIFT))
        self.assertIn(f"`{NEW_TAG}` | `{NEW_REV}` |", self.read(bump.MATRIX))
        self.assertIn(f"As of 2026-11-02 the LM row is `{NEW_TAG}`", self.read(bump.MATRIX))
        self.assertEqual(json.loads(self.read(bump.PACKAGE_RESOLVED))["pins"] and
                         [p["state"]["revision"] for p in json.loads(self.read(bump.PACKAGE_RESOLVED))["pins"]
                          if p["identity"] == "mlx-swift-lm"], [NEW_REV])
        self.assertIn("REMINDER:", out)

    def test_bumps_spec_version_consistently(self):
        rc, _, err = self.run_bump("--skip-regenerate")
        self.assertEqual(rc, 0, err)
        spec = self.read(bump.SPEC)
        self.assertEqual(spec.split("\n")[2], f"**Version:** {self.new_version}")
        self.assertIn(f'  "version": "{self.new_version}",', spec)
        self.assertNotIn(f'  "version": "{self.old_version}",', spec)
        self.assertIn(f"- **{self.new_version} (2026-11-02)** — R003 names mlx-swift-lm `{NEW_TAG}`", spec)
        changelog = spec[spec.index("Changelog and history"):]
        self.assertLess(changelog.index(self.new_version), changelog.index(f"**{self.old_version}"))
        self.assertIn(f"| `https://github.com/Augustas11/mlx-swift-lm.git` | `{NEW_TAG}` | `{NEW_REV}` |", spec)
        self.assertIn(f"The prior mlx-swift-lm row `{self.old_tag}` is ", spec)
        conf = json.loads(self.read(bump.CONFORMANCE))
        self.assertEqual([s["version"] for s in conf["specs"] if s["spec_id"] == "SPEC-048"], [self.new_version])
        rationale = next(r for r in conf["requirements"] if r["requirement_id"] == "SPEC-048-R003")["gap"]["rationale"]
        self.assertTrue(rationale.startswith(f"SPEC-048 v{self.new_version} names LM {NEW_TAG}"), rationale)
        self.assertIn("Prior tuple context: SPEC-048 v" + self.old_version, rationale)

    def test_second_bump_chains_from_the_first(self):
        self.assertEqual(self.run_bump("--skip-regenerate")[0], 0)
        rc, _, err = self.run_bump("--skip-regenerate", tag="9.9.9-macprovider.2", rev="f" * 40)
        self.assertEqual(rc, 0, err)
        self.assertIn(f"The prior mlx-swift-lm row `{NEW_TAG}` is ", self.read(bump.SPEC))

    def test_refuses_when_a_site_drifted_and_writes_nothing(self):
        kv = self.read(bump.KV_ADAPTER).replace(self.old_rev, "e" * 40)
        (self.root / bump.KV_ADAPTER).write_text(kv)
        before = self.snapshot()
        rc, _, err = self.run_bump("--skip-regenerate")
        self.assertEqual(rc, 1)
        self.assertIn("REFUSED", err)
        self.assertIn(bump.KV_ADAPTER, err)
        self.assertEqual(self.snapshot(), before)

    def test_refuses_an_ambiguous_site(self):
        swift = self.read(bump.PACKAGE_SWIFT)
        (self.root / bump.PACKAGE_SWIFT).write_text(swift + f"\n// Tag {self.old_tag} again\n")
        before = self.snapshot()
        rc, _, err = self.run_bump("--skip-regenerate")
        self.assertEqual(rc, 1)
        self.assertIn("found 2", err)
        self.assertEqual(self.snapshot(), before)

    def test_refuses_mismatched_spec_versions(self):
        conf = self.read(bump.CONFORMANCE).replace(f'"version": "{self.old_version}"', '"version": "0.0.1"', 1)
        (self.root / bump.CONFORMANCE).write_text(conf)
        rc, _, err = self.run_bump("--skip-regenerate")
        self.assertEqual(rc, 1)
        self.assertIn("SPEC-048", err)

    def test_refuses_the_current_pin_and_bad_inputs(self):
        self.assertEqual(self.run_bump("--skip-regenerate", tag=self.old_tag, rev=self.old_rev)[0], 1)
        self.assertEqual(self.run_bump("--skip-regenerate", rev="ABC")[0], 2)
        self.assertEqual(self.run_bump("--skip-regenerate", tag="main")[0], 2)

    def test_regenerates_then_checks(self):
        calls = []

        def fake_run(command, cwd=None, env=None):
            calls.append(command)
            return mock.Mock(returncode=0)

        with mock.patch.object(bump.subprocess, "run", side_effect=fake_run):
            rc, _, err = self.run_bump()
        self.assertEqual(rc, 0, err)
        self.assertEqual(calls, bump.REGENERATE + bump.CHECKS)
        self.assertIn(["python3", "scripts/decode_path_digest.py", "--write"], calls)
        self.assertIn(["python3", "-m", "unittest", "scripts.tests.test_upstream_watch"], calls)

    def test_a_failing_check_fails_the_bump(self):
        with mock.patch.object(bump.subprocess, "run",
                               side_effect=lambda command, cwd=None, env=None: mock.Mock(
                                   returncode=1 if "--check" in command else 0)):
            rc, _, err = self.run_bump()
        self.assertEqual(rc, 1)
        self.assertIn("FAILED", err)


if __name__ == "__main__":
    unittest.main()
