#!/usr/bin/env python3
"""Hermetic tests for `catalog-release.py content-gate` and `check-tier2-binding
--require-serving` (#1688 C2/C3).

Fixtures start from the committed release (phase3-binary/catalog/autotune plus
phase3-binary/dist/static) and mutate copies. A mutated release no longer carries
valid signatures, so rule tests replace `verify_directory` with a pass-through;
the real verify-directory path is exercised by the identical-release and
invalid-release tests.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

from scripts.tests.test_catalog_compare_live import (
    CANONICAL,
    LEDGER,
    SCRIPT,
    STATIC,
    STATIC_FILES,
    assemble,
    change_content,
    cr,
    edit_json,
)

MODEL_KEY = "qwen3-8b"
NEW_HASH = "ab" * 32
GENERATED_AT = datetime.fromisoformat(
    json.loads((CANONICAL / "autotune-candidates.json").read_bytes())["generated_at"].replace("Z", "+00:00")
)
NOW = GENERATED_AT + timedelta(days=1)
NO_EXCLUSIONS = json.dumps({"schema_version": cr.NOT_BUYER_SERVING_SCHEMA, "models": []}).encode()


def model_id(directory: Path, key: str = MODEL_KEY) -> str:
    return json.loads((directory / "autotune-candidates.json").read_bytes())["rows"][key]["model_id"]


def correct_hash(directory: Path, key: str = MODEL_KEY, tier2_hash: str = NEW_HASH) -> None:
    """Non-pricing content correction: a candidate model hash plus its matching Tier-2 pin."""
    served = model_id(directory, key)
    edit_json(directory / "autotune-candidates.json", lambda o: o["rows"][key].update(model_sha256=NEW_HASH))

    def tier2(o: dict) -> None:
        for entry in o["models"]:
            if entry["model_id"].lower() == served.lower():
                entry["sha256"] = tier2_hash

    edit_json(directory / "tier2-catalog.json", tier2, compact=False)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


class ContentGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.release = assemble(self.tmp / "release")
        self.live = assemble(self.tmp / "live")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def gate(self, *, verify: bool = False, **kwargs) -> dict:
        kwargs.setdefault("now", NOW)
        kwargs.setdefault("exclusions_data", NO_EXCLUSIONS)
        if verify:
            return cr.content_gate(self.release, self.live, LEDGER, **kwargs)
        with mock.patch.object(cr, "verify_directory", lambda _directory: None):
            return cr.content_gate(self.release, self.live, LEDGER, **kwargs)

    def assertLane(self, result: dict, lane: str) -> None:
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["lane"], lane, result)

    def test_non_pricing_hash_correction_is_eligible(self) -> None:
        correct_hash(self.release)
        result = self.gate()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["lane"], "catalog-content")
        self.assertEqual(result["reasons"], [])
        self.assertTrue(result["changed"]["tier2_models_changed"])
        self.assertIn("autotune-candidates.json", result["changed"]["feeds"])
        self.assertFalse(result["changed"]["rate_card_rows_changed"])

    def test_identical_release_is_freshness_or_noop_with_real_verify_directory(self) -> None:
        result = self.gate(verify=True)
        self.assertLane(result, "freshness-or-noop")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "content-gate", "--release", str(self.release), "--live", str(self.live)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertEqual(len(proc.stdout.splitlines()), 1, proc.stdout)
        self.assertEqual(json.loads(proc.stdout)["lane"], "freshness-or-noop")

    def test_unsigned_content_change_is_invalid_release(self) -> None:
        correct_hash(self.release)
        result = self.gate(verify=True)
        self.assertLane(result, "invalid-release")
        self.assertTrue(result["reasons"][0].startswith("verify-directory:"), result)

    def test_policy_version_change_needs_full_provider_app(self) -> None:
        correct_hash(self.release)
        edit_json(self.release / "release.json", lambda o: o.update(policy_version="autotune-policy-v2"), compact=False)
        result = self.gate()
        self.assertLane(result, "full-provider-app")
        self.assertTrue(any(r.startswith("policy_version changed") for r in result["reasons"]), result)

    def test_signer_change_needs_full_provider_app(self) -> None:
        correct_hash(self.release)
        edit_json(
            self.release / "release.json",
            lambda o: o["feeds"]["demand-rank.json"].update(signer_key_id="streamvc-autotune-static-v5"),
            compact=False,
        )
        self.assertLane(self.gate(), "full-provider-app")

    def test_keyring_change_needs_full_provider_app(self) -> None:
        correct_hash(self.release)
        path = self.release / "trusted-keys.json"
        path.write_bytes(path.read_bytes() + b"\n")
        result = self.gate()
        self.assertLane(result, "full-provider-app")
        self.assertIn("trusted-keys.json bytes changed vs live", result["reasons"])
        self.assertTrue(result["changed"]["trusted_keys_changed"])

    def test_rate_card_row_change_is_pricing(self) -> None:
        correct_hash(self.release)

        def reprice(o: dict) -> None:
            o["rows"][MODEL_KEY]["completion_rate_per_mtok"] += 1
            o["version"] = cr.rate_card_projection_hash(o)

        edit_json(self.release / "rate-card.json", reprice)
        result = self.gate()
        self.assertLane(result, "pricing")
        self.assertTrue(any("#1693" in r for r in result["reasons"]), result)

    def test_rate_card_restamp_alone_is_not_pricing(self) -> None:
        correct_hash(self.release)
        edit_json(self.release / "rate-card.json", lambda o: o.update(generated_at="2026-10-01T00:00:00Z"))
        self.assertTrue(self.gate()["ok"])

    def test_stale_candidates_are_not_eligible(self) -> None:
        correct_hash(self.release)
        result = self.gate(now=GENERATED_AT + timedelta(days=31))
        self.assertLane(result, "stale-or-future")
        self.assertTrue(any("older than 30 days" in r for r in result["reasons"]), result)

    def test_future_candidates_are_not_eligible(self) -> None:
        correct_hash(self.release)
        result = self.gate(now=GENERATED_AT - timedelta(minutes=11))
        self.assertLane(result, "stale-or-future")
        self.assertTrue(self.gate(now=GENERATED_AT - timedelta(minutes=9))["ok"])

    def test_unknown_predecessor_is_not_eligible(self) -> None:
        correct_hash(self.release)
        change_content(self.live)
        result = self.gate()
        self.assertLane(result, "unknown-predecessor")

    def test_restamped_live_tier2_descends_only_with_content_index(self) -> None:
        # Live is a Tier-2 freshness re-sign of the ledger row (same signer and
        # schema); the release moves Tier-2 models. Only the history index can
        # prove the live predecessor (same fixture as compare-live's index test).
        def resign(o: dict) -> None:
            o.update(issued_at="2026-10-01T03:00:00Z", expires_at="2099-01-01T00:00:00Z",
                     catalog_id="macprovider-tier2-model-catalog-2026-10-01-renewal")
            o["signature"]["sig"] = "A" * 86

        edit_json(self.live / "tier2-catalog.json", resign, compact=False)
        correct_hash(self.release)
        self.assertLane(self.gate(), "unknown-predecessor")
        raw = (CANONICAL / "tier2-catalog.json").read_bytes()
        index = self.tmp / "tier2-index.json"
        index.write_text(json.dumps({cr.sha256(raw): cr.tier2_stripped_sha256(raw, "t")}))
        result = self.gate(tier2_index_path=index)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["lane"], "catalog-content")
        with mock.patch.object(cr, "verify_directory", lambda _directory: None), \
                mock.patch.object(cr, "NOT_BUYER_SERVING_PATH", self.tmp / "none.json"):
            (self.tmp / "none.json").write_bytes(NO_EXCLUSIONS)
            for extra, code in (([], cr.CONTENT_GATE_EXIT_NOT_ELIGIBLE), (["--tier2-content-index", str(index)], 0)):
                with self.subTest(extra=extra), mock.patch.object(
                    sys, "argv",
                    ["catalog-release.py", "content-gate", "--release", str(self.release), "--live", str(self.live),
                     "--ledger", str(LEDGER), "--now", NOW.isoformat().replace("+00:00", "Z"), *extra],
                ), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(cr.main(), code)

    def test_serving_closure_failure_is_not_eligible(self) -> None:
        correct_hash(self.release, tier2_hash="cd" * 32)
        result = self.gate()
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["lane"], "invalid-release", result)

    def test_cli_rejects_malformed_input(self) -> None:
        (self.release / "release.json").write_text("{not json")
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "content-gate", "--release", str(self.release), "--live", str(self.live)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout)


class ContentGateCommitTests(unittest.TestCase):
    """--commit checks run against a throwaway repo with an origin/main ref."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        static = self.repo / "phase3-binary" / "dist" / "static"
        catalog = self.repo / "phase3-binary" / "catalog" / "autotune"
        static.mkdir(parents=True)
        catalog.mkdir(parents=True)
        for name in STATIC_FILES:
            shutil.copyfile(STATIC / name, static / name)
        for name in ("release.json", "trusted-keys.json", "tier2-catalog.json"):
            shutil.copyfile(CANONICAL / name, catalog / name)
        git(self.repo.parent, "init", "-q", str(self.repo))
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "release")
        self.sha = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "update-ref", "refs/remotes/origin/main", self.sha)
        self.release = assemble(self.tmp / "release")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def test_committed_bytes_match(self) -> None:
        self.assertEqual(cr.content_gate_commit_reasons(self.release, self.sha, self.repo), [])

    def test_byte_mismatch_is_rejected(self) -> None:
        change_content(self.release)
        reasons = cr.content_gate_commit_reasons(self.release, self.sha, self.repo)
        self.assertTrue(any(r.startswith("demand-rank.json bytes differ") for r in reasons), reasons)

    def test_extra_uncommitted_file_is_rejected(self) -> None:
        (self.release / cr.ARTIFACT_FEED_NAME).write_bytes(b"{}")
        reasons = cr.content_gate_commit_reasons(self.release, self.sha, self.repo)
        self.assertTrue(any(r.startswith(cr.ARTIFACT_FEED_NAME) for r in reasons), reasons)

    def test_commit_off_origin_main_is_rejected(self) -> None:
        (self.repo / "side.txt").write_text("x")
        git(self.repo, "add", "side.txt")
        git(self.repo, "commit", "-q", "-m", "side")
        side = git(self.repo, "rev-parse", "HEAD")
        reasons = cr.content_gate_commit_reasons(self.release, side, self.repo)
        self.assertEqual(reasons, [f"commit {side} is not an ancestor of origin/main"])

    def test_gate_reports_commit_mismatch_lane(self) -> None:
        live = assemble(self.tmp / "live")
        correct_hash(self.release)
        with mock.patch.object(cr, "verify_directory", lambda _directory: None):
            result = cr.content_gate(
                self.release, live, LEDGER, commit=self.sha, now=NOW,
                exclusions_data=NO_EXCLUSIONS, repo=self.repo,
            )
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["lane"], "unverified-commit", result)

    def test_commit_without_ledger_or_exclusions_is_unverified(self) -> None:
        live = assemble(self.tmp / "live")
        with mock.patch.object(cr, "verify_directory", lambda _directory: None):
            result = cr.content_gate(self.release, live, LEDGER, commit=self.sha, now=NOW, repo=self.repo)
        self.assertEqual(result["lane"], "unverified-commit", result)
        self.assertTrue(any("lacks" in r for r in result["reasons"]), result)

    def test_commit_supplies_ledger_and_exclusions(self) -> None:
        catalog = self.repo / "phase3-binary" / "catalog" / "autotune"
        shutil.copyfile(LEDGER, catalog / "release-ledger.json")
        (catalog / "not-buyer-serving.json").write_bytes(NO_EXCLUSIONS)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "ledger")
        sha = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "update-ref", "refs/remotes/origin/main", sha)
        live = assemble(self.tmp / "live")
        # A bogus working-tree ledger must not be consulted when --commit is given.
        bogus = self.tmp / "bogus-ledger.json"
        bogus.write_text("{not json")
        with mock.patch.object(cr, "verify_directory", lambda _directory: None):
            result = cr.content_gate(self.release, live, bogus, commit=sha, now=NOW, repo=self.repo)
        self.assertNotIn("unverified-commit", {result["lane"]}, result)
        self.assertEqual(result["lane"], "freshness-or-noop", result)


class ServingClosureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.candidate = (CANONICAL / "autotune-candidates.json").read_bytes()
        self.rate_card = (CANONICAL / "rate-card.json").read_bytes()
        self.tier2_obj = json.loads((CANONICAL / "tier2-catalog.json").read_bytes())
        self.served = json.loads(self.candidate)["rows"][MODEL_KEY]["model_id"]

    def tier2(self) -> bytes:
        return json.dumps(self.tier2_obj).encode()

    def check(self, excluded: set[str] = frozenset()) -> None:
        cr.check_serving_closure(self.candidate, self.rate_card, self.tier2(), set(excluded))

    def test_committed_release_is_closed(self) -> None:
        self.check()

    def test_missing_tier2_for_serving_model_fails(self) -> None:
        self.tier2_obj["models"] = [m for m in self.tier2_obj["models"] if m["model_id"].lower() != self.served.lower()]
        with self.assertRaisesRegex(cr.CatalogError, "serving closure: 1 "):
            self.check()

    def test_excluded_serving_model_passes(self) -> None:
        self.tier2_obj["models"] = [m for m in self.tier2_obj["models"] if m["model_id"].lower() != self.served.lower()]
        self.check({self.served.lower()})

    def test_stale_exclusion_of_pinned_model_fails(self) -> None:
        # The release pins the model (Tier-2 model_id+sha256 match), so it is
        # buyer-serving whatever not-buyer-serving.json says.
        with self.assertRaisesRegex(cr.CatalogError, f"remove the exclusion: {self.served} is structurally buyer-serving"):
            self.check({self.served.lower()})

    def test_hash_mismatch_fails(self) -> None:
        for entry in self.tier2_obj["models"]:
            if entry["model_id"].lower() == self.served.lower():
                entry["sha256"] = "cd" * 32
        with self.assertRaises(cr.CatalogError):
            self.check({self.served.lower()})  # binding conflict is never excusable

    def test_committed_exclusions_file_is_valid(self) -> None:
        cr.load_serving_exclusions(cr.NOT_BUYER_SERVING_PATH.read_bytes(), "not-buyer-serving.json")

    def test_exclusions_schema_is_closed(self) -> None:
        for bad in (
            {"schema_version": "x", "models": []},
            {"schema_version": cr.NOT_BUYER_SERVING_SCHEMA, "models": [{"model_id": self.served}]},
            {"schema_version": cr.NOT_BUYER_SERVING_SCHEMA, "models": [], "extra": 1},
        ):
            with self.assertRaises(cr.CatalogError):
                cr.load_serving_exclusions(json.dumps(bad).encode(), "t")

    def test_cli_require_serving_with_exclusions_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tier2_path = Path(tmp) / "tier2.json"
            excl_path = Path(tmp) / "excl.json"
            self.tier2_obj["models"] = [m for m in self.tier2_obj["models"] if m["model_id"].lower() != self.served.lower()]
            tier2_path.write_bytes(self.tier2())
            base = [sys.executable, str(SCRIPT), "check-tier2-binding", "--require-serving",
                    "--candidate", str(CANONICAL / "autotune-candidates.json"),
                    "--rate-card", str(CANONICAL / "rate-card.json"), "--tier2", str(tier2_path)]
            proc = subprocess.run(base, capture_output=True, text=True, check=False)
            self.assertEqual(proc.returncode, 1, proc.stdout)
            self.assertIn(self.served, proc.stderr)
            excl_path.write_text(json.dumps({"schema_version": cr.NOT_BUYER_SERVING_SCHEMA,
                                             "models": [{"model_id": self.served, "reason": "test"}]}))
            proc = subprocess.run(base + ["--exclusions", str(excl_path)], capture_output=True, text=True, check=False)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            # The same exclusion once the pin is back (stale exclusion + new pin).
            pinned = [sys.executable, str(SCRIPT), "check-tier2-binding", "--require-serving",
                      "--candidate", str(CANONICAL / "autotune-candidates.json"),
                      "--rate-card", str(CANONICAL / "rate-card.json"),
                      "--tier2", str(CANONICAL / "tier2-catalog.json"), "--exclusions", str(excl_path)]
            proc = subprocess.run(pinned, capture_output=True, text=True, check=False)
            self.assertEqual(proc.returncode, 1, proc.stdout)
            self.assertIn(f"remove the exclusion: {self.served} is structurally buyer-serving", proc.stderr)
            # Without --require-serving the legacy overlap-only check still passes.
            legacy = subprocess.run(
                [sys.executable, str(SCRIPT), "check-tier2-binding",
                 "--candidate", str(CANONICAL / "autotune-candidates.json"), "--tier2", str(tier2_path)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(legacy.returncode, 0, legacy.stderr)


class BuyerServingSetTests(unittest.TestCase):
    """`buyer-serving-set --diff-live` (#1688 R017 evidence (e)): newly buyer-serving models."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.release = assemble(self.tmp / "release")
        self.live = assemble(self.tmp / "live")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def exclusions(self, name: str, *model_ids: str) -> Path:
        path = self.tmp / name
        entries = [{"model_id": m, "reason": "test"} for m in model_ids]
        path.write_text(json.dumps({"schema_version": cr.NOT_BUYER_SERVING_SCHEMA, "models": entries}))
        return path

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "buyer-serving-set", "--release", str(self.release), *args],
            capture_output=True, text=True, check=False,
        )

    def diff(self, *args: str) -> dict:
        proc = self.run_cli("--diff-live", str(self.live), *args)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(proc.stdout.splitlines()), 1, proc.stdout)
        return json.loads(proc.stdout)

    def test_set_is_every_pinned_recommendable_rate_carded_model(self) -> None:
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        models = json.loads(proc.stdout)["models"]
        candidates = json.loads((self.release / "autotune-candidates.json").read_bytes())["rows"]
        self.assertEqual(len(models), len(candidates))
        self.assertIn({"model_id": model_id(self.release), "sha256": candidates[MODEL_KEY]["model_sha256"]}, models)

    def test_identical_releases_have_empty_diff(self) -> None:
        self.assertEqual(self.diff(), {"added": [], "removed": [], "changed": []})

    def test_listed_to_recommendable_is_added(self) -> None:
        edit_json(self.live / "autotune-candidates.json", lambda o: o["rows"][MODEL_KEY].update(runtime_status="listed"))
        result = self.diff()
        self.assertEqual([m["model_id"] for m in result["added"]], [model_id(self.release)], result)
        self.assertEqual(result["removed"], [])
        self.assertEqual(result["changed"], [])

    def unpin(self, directory: Path) -> None:
        mid = model_id(directory).lower()
        edit_json(directory / "tier2-catalog.json",
                  lambda o: o.update(models=[m for m in o["models"] if m["model_id"].lower() != mid]))

    def test_new_pin_with_exclusion_removed_is_added(self) -> None:
        # Live was excused (excluded, unpinned); the incoming release pins it.
        self.unpin(self.live)
        live_ex = self.exclusions("live-ex.json", model_id(self.live))
        incoming_ex = self.exclusions("incoming-ex.json")
        result = self.diff("--exclusions", str(incoming_ex), "--live-exclusions", str(live_ex))
        self.assertEqual([m["model_id"] for m in result["added"]], [model_id(self.release)], result)
        self.assertEqual(result["removed"], [])

    def test_stale_exclusion_with_new_pin_is_rejected_and_added(self) -> None:
        # The stale exclusion stays while the incoming release adds the pin:
        # the CLI refuses it, and the set itself (exclusions never subtract)
        # still reports the model as newly buyer-serving.
        self.unpin(self.live)
        stale = self.exclusions("stale-ex.json", model_id(self.release))
        proc = self.run_cli("--diff-live", str(self.live), "--exclusions", str(stale), "--live-exclusions", str(stale))
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        self.assertIn(f"remove the exclusion: {model_id(self.release)} is structurally buyer-serving", proc.stderr)
        self.assertEqual(self.run_cli("--exclusions", str(stale)).returncode, 1)
        result = cr.buyer_serving_diff(cr.buyer_serving_set(self.release), cr.buyer_serving_set(self.live))
        self.assertEqual([m["model_id"] for m in result["added"]], [model_id(self.release)], result)

    def test_live_exclusion_does_not_hide_a_live_pin(self) -> None:
        # Live pinned the model while (stalely) excluding it: it was serving,
        # so the incoming release does not newly add it.
        live_ex = self.exclusions("live-ex.json", model_id(self.live))
        result = self.diff("--exclusions", str(self.exclusions("incoming-ex.json")), "--live-exclusions", str(live_ex))
        self.assertEqual(result, {"added": [], "removed": [], "changed": []})

    def test_hash_change_is_changed(self) -> None:
        correct_hash(self.release)
        result = self.diff()
        self.assertEqual(result["added"], [])
        self.assertEqual(result["removed"], [])
        self.assertEqual(len(result["changed"]), 1, result)
        change = result["changed"][0]
        self.assertEqual(change["model_id"], model_id(self.release))
        self.assertEqual(change["sha256"], NEW_HASH)
        self.assertNotEqual(change["live_sha256"], NEW_HASH)

    def test_unpinned_model_is_not_serving(self) -> None:
        # Recommendable + rate-carded but no matching Tier-2 pin: the closure
        # forbids it, so it is not a member (and not "added").
        edit_json(self.release / "autotune-candidates.json", lambda o: o["rows"][MODEL_KEY].update(model_sha256=NEW_HASH))
        result = self.diff()
        self.assertEqual(result["added"], [])
        self.assertEqual([m["model_id"] for m in result["removed"]], [model_id(self.release)], result)

    def test_one_sided_exclusions_are_rejected(self) -> None:
        ex = self.exclusions("ex.json")
        proc = self.run_cli("--diff-live", str(self.live), "--exclusions", str(ex))
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(self.run_cli("--live-exclusions", str(ex)).returncode, 1)

    def test_malformed_release_fails_closed(self) -> None:
        (self.live / "tier2-catalog.json").write_bytes(b"{")
        proc = self.run_cli("--diff-live", str(self.live))
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")



class LiveTier2TrustTests(unittest.TestCase):
    """verify-directory's live-side Tier-2 inputs (#1688): the LIVE coordinator's
    configured key (overlay wins) and --allow-expired-tier2."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def key(self) -> str:
        import base64
        import os

        return base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()

    def yaml(self, name: str, body: str) -> Path:
        path = self.tmp / name
        path.write_text(body)
        return path.resolve()

    def test_overlay_key_wins_over_base_config(self) -> None:
        base, over = self.key(), self.key()
        config = self.yaml("coordinator.yaml", f"tier2:\n  catalog_public_key: {base}\n")
        overlay = self.yaml("overlay.yaml", f"tier2:\n  catalog_public_key: {over}\n")
        self.assertEqual(cr.load_tier2_trusted_public_key(None, config, overlay), over)

    def test_overlay_without_tier2_key_keeps_base_key(self) -> None:
        base = self.key()
        config = self.yaml("coordinator.yaml", f"tier2:\n  catalog_public_key: {base}\n")
        overlay = self.yaml("overlay.yaml", "billing:\n  enabled: true\n")
        self.assertEqual(cr.load_tier2_trusted_public_key(None, config, overlay), base)

    def test_overlay_requires_base_config(self) -> None:
        overlay = self.yaml("overlay.yaml", f"tier2:\n  catalog_public_key: {self.key()}\n")
        with self.assertRaises(cr.CatalogError):
            cr.load_tier2_trusted_public_key(None, None, overlay)

    def test_expired_tier2_needs_the_explicit_flag(self) -> None:
        tier2 = json.loads((CANONICAL / "tier2-catalog.json").read_bytes())
        tier2["issued_at"], tier2["expires_at"] = "2020-01-01T00:00:00Z", "2020-02-01T00:00:00Z"
        raw = json.dumps(tier2).encode()
        with self.assertRaisesRegex(cr.CatalogError, "expired"):
            cr.validate_tier2_catalog(raw)
        self.assertEqual(cr.validate_tier2_catalog(raw, allow_expired=True)["catalog_id"], tier2["catalog_id"])

    def test_cli_exposes_live_side_flags(self) -> None:
        proc = subprocess.run([sys.executable, str(SCRIPT), "verify-directory", "--help"], capture_output=True, text=True, check=True)
        self.assertIn("--allow-expired-tier2", proc.stdout)
        self.assertIn("--tier2-coordinator-overlay", proc.stdout)


if __name__ == "__main__":
    unittest.main()
