#!/usr/bin/env python3
"""Hermetic tests for `catalog-release.py compare-live` (#1688 A2).

Fixtures start from the committed release (phase3-binary/catalog/autotune plus
phase3-binary/dist/static) and its real release-ledger.json, then mutate copies.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "catalog-release.py"
SPEC = importlib.util.spec_from_file_location("catalog_release", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
cr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cr)

CANONICAL = REPO / "phase3-binary" / "catalog" / "autotune"
STATIC = REPO / "phase3-binary" / "dist" / "static"
LEDGER = CANONICAL / "release-ledger.json"
STATIC_FILES = (
    "demand-rank.json", "demand-rank.json.sig",
    "autotune-candidates.json", "autotune-candidates.json.sig",
    "rate-card.json", "rate-card.json.sig",
)


def assemble(dest: Path) -> Path:
    dest.mkdir(parents=True)
    for name in STATIC_FILES:
        shutil.copyfile(STATIC / name, dest / name)
    for name in ("release.json", "trusted-keys.json", "tier2-catalog.json"):
        shutil.copyfile(CANONICAL / name, dest / name)
    return dest


def edit_json(path: Path, mutate, compact: bool = True) -> None:
    obj = json.loads(path.read_bytes())
    mutate(obj)
    path.write_bytes(cr.canonical_bytes(obj) if compact else json.dumps(obj, indent=2).encode())


def restamp(directory: Path, release_id: str, generated_at: str) -> None:
    """What renew-autotune-static-feed.sh leaves on Pearl: same content, new identity."""
    for name in ("autotune-candidates.json", "demand-rank.json"):
        edit_json(directory / name, lambda o: o.update(version=release_id, generated_at=generated_at))
    edit_json(directory / "rate-card.json", lambda o: o.update(generated_at=generated_at))

    def manifest(o: dict) -> None:
        o["release_id"] = release_id
        o["generated_at"] = generated_at
        for name in ("autotune-candidates.json", "demand-rank.json", "rate-card.json"):
            raw = (directory / name).read_bytes()
            o["feeds"][name].update(sha256=cr.sha256(raw), bytes=len(raw))
            if name != "rate-card.json":
                o["feeds"][name]["version"] = release_id

    edit_json(directory / "release.json", manifest, compact=False)


def restamp_tier2(directory: Path) -> None:
    """A Tier-2 freshness re-sign: every `_TIER2_ENVELOPE_FIELDS` value rewritten, models kept."""
    def envelope(o: dict) -> None:
        o.update(
            issued_at="2026-10-01T03:00:00Z",
            expires_at="2099-01-01T00:00:00Z",
            catalog_id="macprovider-tier2-model-catalog-2026-10-01-renewal",
            version=2,
            signature={"alg": "Ed25519", "key_id": "tier2-renewal", "sig": "A" * 86},
        )

    edit_json(directory / "tier2-catalog.json", envelope, compact=False)


def change_content(directory: Path) -> None:
    edit_json(directory / "demand-rank.json", lambda o: o.update(compare_live_test_marker=True))


class CompareLiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.incoming = assemble(self.tmp / "incoming")
        self.live = assemble(self.tmp / "live")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def verdict(self) -> dict:
        return cr.compare_live(self.incoming, self.live, LEDGER)

    def run_cli(self, ledger: Path = LEDGER) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "compare-live", "--incoming", str(self.incoming),
             "--live", str(self.live), "--ledger", str(ledger)],
            capture_output=True, text=True, check=False,
        )

    def test_identical_release_is_equivalent(self) -> None:
        result = self.verdict()
        self.assertEqual(result["verdict"], "equivalent", result)
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["verdict"], "equivalent")

    def test_uncommitted_renewal_restamp_is_equivalent(self) -> None:
        restamp(self.live, "published-2026-10-01-renewal-v1", "2026-10-01T03:00:00Z")
        result = self.verdict()
        self.assertEqual(result["verdict"], "equivalent", result)
        self.assertEqual(result["live_release_id"], "published-2026-10-01-renewal-v1")

    def test_fresher_tier2_in_tag_is_not_equivalent(self) -> None:
        edit_json(self.incoming / "tier2-catalog.json", lambda o: o.update(expires_at="2099-01-01T00:00:00Z"))
        result = self.verdict()
        self.assertNotEqual(result["verdict"], "equivalent")
        self.assertTrue(any("fresher Tier-2" in r for r in result["reasons"]), result)
        # Live still equals the committed ledger release, so the tag activates.
        self.assertEqual(result["verdict"], "descends")

    def test_fresher_live_tier2_with_same_models_is_kept(self) -> None:
        # A live Tier-2 re-sign with the same models must not be rolled back by
        # a runtime deploy carrying the older envelope.
        edit_json(self.live / "tier2-catalog.json", lambda o: o.update(expires_at="2099-01-01T00:00:00Z"))
        self.assertEqual(self.verdict()["verdict"], "equivalent")

    def test_live_tier2_with_other_models_outside_ledger_is_regression(self) -> None:
        edit_json(self.live / "tier2-catalog.json", lambda o: o["models"].pop())
        result = self.verdict()
        self.assertEqual(result["verdict"], "regression", result)
        self.assertIn("tier2-catalog.json content differs", result["reasons"])

    def test_renewed_live_of_ledger_release_descends_to_new_content(self) -> None:
        restamp(self.live, "published-2026-10-01-renewal-v1", "2026-10-01T03:00:00Z")
        change_content(self.incoming)
        result = self.verdict()
        self.assertEqual(result["verdict"], "descends", result)
        self.assertEqual(result["matched_ledger_release"], json.loads((CANONICAL / "release.json").read_bytes())["release_id"])
        self.assertEqual(self.run_cli().returncode, 0)

    def test_renewed_live_with_restamped_tier2_envelope_descends(self) -> None:
        # A freshness re-sign rewrites every Tier-2 envelope field; the ledger
        # row still names the committed Tier-2 bytes, which the incoming tag carries.
        restamp(self.live, "published-2026-10-01-renewal-v1", "2026-10-01T03:00:00Z")
        restamp_tier2(self.live)
        change_content(self.incoming)
        result = self.verdict()
        self.assertEqual(result["verdict"], "descends", result)
        self.assertEqual(result["matched_ledger_release"], json.loads((CANONICAL / "release.json").read_bytes())["release_id"])

    def test_restamped_tier2_with_changed_models_is_regression(self) -> None:
        restamp_tier2(self.live)
        edit_json(self.live / "tier2-catalog.json", lambda o: o["models"].pop(), compact=False)
        change_content(self.incoming)
        self.assertEqual(self.verdict()["verdict"], "regression")

    def test_restamped_tier2_is_unprovable_when_incoming_tier2_moved(self) -> None:
        # Documented limit: the ledger stores only whole-file Tier-2 digests, so a
        # re-signed live Tier-2 is provable only against bytes the tag carries.
        restamp_tier2(self.live)
        edit_json(self.incoming / "tier2-catalog.json", lambda o: o["models"].pop(), compact=False)
        self.assertEqual(self.verdict()["verdict"], "regression")

    def test_live_content_outside_ledger_is_regression(self) -> None:
        change_content(self.live)
        result = self.verdict()
        self.assertEqual(result["verdict"], "regression", result)
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["verdict"], "regression")

    def test_renewed_live_with_changed_content_is_regression(self) -> None:
        change_content(self.live)
        restamp(self.live, "published-2026-10-01-renewal-v1", "2026-10-01T03:00:00Z")
        self.assertEqual(self.verdict()["verdict"], "regression")

    def test_artifact_bound_vs_unbound_is_not_equivalent(self) -> None:
        artifact = {"models": [], "version": "x", "release_id": "x", "generated_at": "2026-09-23T02:11:36Z",
                    "candidate_catalog_sha256": "0" * 64, "policy_version": "autotune-policy-v1", "source": "s"}
        (self.live / "autotune-artifacts.json").write_bytes(cr.canonical_sorted_bytes(artifact))

        def bind(o: dict) -> None:
            o["feeds"]["autotune-artifacts.json"] = dict(o["feeds"]["autotune-candidates.json"])

        edit_json(self.live / "release.json", bind, compact=False)
        result = self.verdict()
        self.assertEqual(result["verdict"], "regression", result)
        self.assertIn("autotune-artifacts.json content differs", result["reasons"])

    def test_trusted_keys_difference_is_not_equivalent(self) -> None:
        (self.incoming / "trusted-keys.json").write_bytes((self.incoming / "trusted-keys.json").read_bytes() + b"\n")
        result = self.verdict()
        self.assertIn("trusted-keys.json differs", result["reasons"])
        self.assertEqual(result["verdict"], "descends")

    def test_malformed_inputs_fail_closed(self) -> None:
        cases = {
            "live release.json not JSON": lambda: (self.live / "release.json").write_bytes(b"{"),
            "live tier2 missing": lambda: (self.live / "tier2-catalog.json").unlink(),
            "incoming candidates missing": lambda: (self.incoming / "autotune-candidates.json").unlink(),
            "live release.json without feeds": lambda: (self.live / "release.json").write_bytes(b'{"release_id":"x"}'),
            "live tier2 bad expiry": lambda: edit_json(self.live / "tier2-catalog.json", lambda o: o.update(expires_at="soon")),
        }
        for label, breaker in cases.items():
            with self.subTest(label):
                shutil.rmtree(self.incoming)
                shutil.rmtree(self.live)
                assemble(self.incoming)
                assemble(self.live)
                breaker()
                proc = self.run_cli()
                self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
                self.assertEqual(proc.stdout, "")

    def test_malformed_ledger_fails_closed(self) -> None:
        bad = self.tmp / "ledger.json"
        bad.write_bytes(b'{"schema_version":"nope","releases":{}}')
        self.assertEqual(self.run_cli(bad).returncode, 1)
        self.assertEqual(self.run_cli(self.tmp / "missing.json").returncode, 1)


if __name__ == "__main__":
    unittest.main()
