"""scripts/ops/lib/catalog-cut-scope.py: when cli-release may cut before the
committed catalog is live (a first native-MTP admission scope needs this cut).
"""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("catalog_cut_scope", ROOT / "scripts/ops/lib/catalog-cut-scope.py")
cut = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cut)

AUTOTUNE = "phase3-binary/catalog/autotune"
SWIFT = "phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"


def entry(model: str) -> dict:
    return {"model_key": model, "artifact_hash": f"art-{model}", "hardware_class": "apple-silicon:Apple M3 Ultra:ram-256gb",
            "ram_bytes": 274877906944, "qualified_slots": 4, "decode_path_digest": "d" * 64}


def stamped(rid: str, at: str) -> dict:
    rate = {"generated_at": at, "policy_version": "p1", "version": "card-v1",
            "rows": {"m-a": {"prompt_rate_per_mtok": 10}, "m-b": {"prompt_rate_per_mtok": 10}}}
    common = {"generated_at": at, "version": rid, "policy_version": "p1"}
    return {
        "rate-card.json": rate,
        "demand-rank.json": dict(common, rows=["m-a", "m-b"]),
        "autotune-candidates.json": dict(common, candidates=[{"model_key": "m-a"}, {"model_key": "m-b"}]),
        "autotune-artifacts.json": dict(common, release_id=rid, candidate_catalog_sha256=rid * 2, artifacts=[1]),
        "continuous-batching-policy.json": dict(common, release_id=rid, candidate_catalog_sha256=rid * 2, entries=[
            {"model_key": "m-a", "rollout": "on", "tuple_sha256": rid}]),
    }


class CatalogCutScopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.tmp.name) / "repo"
        self.live = pathlib.Path(self.tmp.name) / "live"
        self.live.mkdir()
        self.repo.mkdir()
        self.git("init", "-q")
        # The bound CLI (1.0.1) packaged m-a's admission scope only.
        self.write(SWIFT, '    static let binaryVersion = "1.0.1"\n')
        self.write(f"{AUTOTUNE}/native-mtp-admission.json", {"entries": [entry("m-a")]})
        self.bound = self.commit("bound release")
        # Live: the previous catalog release, served byte for byte.
        self.live_feeds = stamped("rel-live", "2026-10-30T06:00:00Z")
        self.serve(self.live_feeds, "rel-live")
        # Committed: the next release adds m-b's scope and m-b's CB entry.
        self.feeds = stamped("rel-new", "2026-11-01T05:00:00Z")
        self.feeds["continuous-batching-policy.json"]["entries"].insert(
            0, {"model_key": "m-b", "rollout": "canary", "tuple_sha256": "x"})
        self.binding = {"release_id": "rel-new", "entry": {"source_commit": self.bound}}
        self.admission = {"entries": [entry("m-a"), entry("m-b")]}
        self.version = "1.0.2"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()

    def write(self, path: str, body) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body if isinstance(body, str) else json.dumps(body))

    def commit(self, message: str) -> str:
        self.git("add", ".")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def serve(self, feeds: dict, rid: str, policy: str = "p1") -> None:
        digests = {}
        for name, (key, route) in cut.FEEDS.items():
            body = json.dumps(feeds[name]).encode()
            (self.live / route).write_bytes(body)
            digests[key] = {"sha256": hashlib.sha256(body).hexdigest()}
        (self.live / "autotune-release").write_text(json.dumps(
            {"release_id": rid, "generated_at": "2026-10-30T06:00:00Z", "policy_version": policy, "feeds": digests}))

    def classify(self) -> str:
        self.write(SWIFT, f'    static let binaryVersion = "{self.version}"\n')
        self.write(f"{AUTOTUNE}/release.json", {"release_id": "rel-new", "policy_version": "p1"})
        self.write(f"{AUTOTUNE}/native-mtp-admission-release.json", self.binding)
        self.write(f"{AUTOTUNE}/native-mtp-admission.json", self.admission)
        for name, body in self.feeds.items():
            self.write(f"{AUTOTUNE}/{name}", body)
        head = self.commit("catalog")
        try:
            return cut.classify(self.repo, head, self.version, self.live)
        except cut.Blocked as exc:
            return f"blocked: {exc}"

    def test_first_admission_scope_and_its_cb_entry_may_cut_first(self) -> None:
        self.assertEqual(self.classify(), "admission_scope_only: m-b")

    def test_price_change_blocks(self) -> None:
        self.feeds["rate-card.json"]["rows"]["m-a"]["prompt_rate_per_mtok"] = 11
        self.assertIn("rate-card.json differs from live", self.classify())

    def test_rate_card_content_version_change_blocks(self) -> None:
        self.feeds["rate-card.json"]["version"] = "card-v2"
        self.assertIn("rate-card.json differs from live", self.classify())

    def test_model_row_change_blocks(self) -> None:
        self.feeds["autotune-candidates.json"]["candidates"].append({"model_key": "m-c"})
        self.assertIn("autotune-candidates.json differs from live", self.classify())

    def test_cb_entry_for_another_model_blocks(self) -> None:
        self.feeds["continuous-batching-policy.json"]["entries"].append({"model_key": "m-c", "tuple_sha256": "y"})
        self.assertIn("adds entries for ['m-c']", self.classify())

    def test_cb_change_to_a_live_entry_blocks(self) -> None:
        self.feeds["continuous-batching-policy.json"]["entries"][1]["rollout"] = "canary"
        self.assertIn("changes or removes a live entry", self.classify())

    def test_scope_already_packaged_blocks(self) -> None:
        self.admission = {"entries": [entry("m-a")]}
        self.feeds["continuous-batching-policy.json"] = copy.deepcopy(self.live_feeds["continuous-batching-policy.json"])
        self.assertIn("does not need this cut", self.classify())

    def test_binding_not_older_than_candidate_blocks(self) -> None:
        self.version = "1.0.1"
        self.assertIn("not a CLI older than v1.0.1", self.classify())

    def test_binding_for_another_release_blocks(self) -> None:
        self.binding["release_id"] = "rel-other"
        self.assertIn("binds 'rel-other'", self.classify())

    def test_unverified_live_feed_blocks(self) -> None:
        (self.live / "demand-rank").write_text("{}")
        self.assertIn("demand-rank does not verify", self.classify())

    def test_missing_live_feed_blocks(self) -> None:
        (self.live / "catalog-artifacts").unlink()
        self.assertIn("catalog-artifacts does not verify", self.classify())

    def test_policy_version_change_blocks(self) -> None:
        self.serve(self.live_feeds, "rel-live", policy="p0")
        self.assertIn("policy_version", self.classify())

    def test_live_already_committed_is_not_this_case(self) -> None:
        self.serve(self.live_feeds, "rel-new")
        self.assertIn("already serves the committed release", self.classify())


if __name__ == "__main__":
    unittest.main()
