#!/usr/bin/env python3
"""#1816: pool_setup.py signs pool model entries only through coordinator-cli.

A fake coordinator-cli records each sign-manifest call. The cases check that a
pool_model_proposal.v1 bundle becomes exactly one R015 entry, that a
malformed or foreign-pool bundle is refused, that the next manifest passes
the staged entries file and chains windows, and that removing the last entry
omits the extension (the revocation path).

  python3 scripts/lab/1690-m6/test_pool_setup_model_entries.py
"""
import importlib.util
import json
import pathlib
import tempfile
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent
POOL_ID = "AbCdEfGhIjKlMnOpQrStUv"


def load_pool_setup(lab):
    spec = importlib.util.spec_from_file_location("pool_setup_entries_under_test", HERE / "pool_setup.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.LAB = lab
    return mod


def proposal(**overrides):
    bundle = {
        "schema_version": "pool_model_proposal.v1",
        "pool_model_id": f"pool/{POOL_ID}/qwen25-05b-q4km",
        "artifact_hash_algorithm": "macprovider.gguf-file.v1",
        "artifact_hash": "a" * 64,
        "allowed_runtime_sources": ["llamacpp_loopback"],
        "license": "Apache-2.0",
        "paid_serving_attested": True,
        "pricing": {"prompt_rate_per_mtok": 20000, "prompt_cache_hit_rate_per_mtok": 5000,
                    "completion_rate_per_mtok": 40000},
        "disclosure_class": "pool_attested_unverified",
        "max_context_tokens": 32768,
    }
    bundle.update(overrides)
    return bundle


class FakeCLI:
    def __init__(self):
        self.calls = []
        self.version = 1

    def __call__(self, *args):
        args = list(args)
        self.calls.append(args)
        assert args[0] == "sign-manifest", args
        out = pathlib.Path(args[args.index("--out") + 1])
        assert not out.exists(), "sign-manifest refuses an existing --out"
        self.version += 1
        out.write_text(json.dumps({"event_type": "manifest_accepted", "manifest_version": self.version,
                                   "manifest_core_digest": "d" * 64}))
        return ""


class ModelEntries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lab = pathlib.Path(self.tmp.name)
        self.mod = load_pool_setup(self.lab)
        self.d = self.lab / "pools" / "P"
        self.d.mkdir(parents=True)
        (self.d / "signer").write_text("coordinator-cli\n")
        (self.d / "pool_id").write_text(POOL_ID + "\n")
        (self.d / "manifest-v1.json").write_text(json.dumps({"manifest_version": 1}))
        (self.d / "windows.json").write_text(json.dumps({"1": [1000, 1600]}))
        self.cli = FakeCLI()
        self.mod.coordinator_cli = self.cli
        self.posted = []
        self.mod.post_event = self.posted.append

    def tearDown(self):
        self.tmp.cleanup()

    def stage(self, bundle):
        path = self.lab / "bundle.json"
        path.write_text(json.dumps(bundle))
        self.mod.entry(types.SimpleNamespace(name="P", proposal=str(path), remove=None, signer="coordinator-cli"))

    def manifest(self):
        self.mod.manifest(types.SimpleNamespace(name="P", encoding=2, runtime_allowlist="llamacpp_loopback",
                                                settlement_mode="enforce", window_seconds=600,
                                                signer="coordinator-cli"))
        return self.cli.calls[-1]

    def test_proposal_becomes_one_entry_and_rides_the_next_manifest(self):
        self.stage(proposal())
        entries = json.loads((self.d / "model-entries.json").read_text())
        expected = proposal()
        del expected["schema_version"]
        self.assertEqual(entries, [expected])
        call = self.manifest()
        self.assertEqual(call[call.index("--model-entries") + 1], str(self.d / "model-entries.json"))
        self.assertEqual(call[call.index("--prev") + 1], str(self.d / "manifest-v1.json"))
        self.assertNotIn("--manifest-authority-key", call)
        # The successor starts when manifest v1 ends (labtool window rule).
        self.assertEqual(call[call.index("--not-before") + 1], self.mod.rfc3339(1600))
        self.assertEqual(call[call.index("--expires-at") + 1], self.mod.rfc3339(2200))
        self.assertEqual(json.loads((self.d / "windows.json").read_text())["2"], [1600, 2200])
        self.assertEqual(self.posted[-1]["manifest_version"], 2)

    def test_entries_stay_sorted_and_unique(self):
        self.stage(proposal(pool_model_id=f"pool/{POOL_ID}/zz-model", artifact_hash="b" * 64))
        self.stage(proposal())
        ids = [e["pool_model_id"] for e in json.loads((self.d / "model-entries.json").read_text())]
        self.assertEqual(ids, sorted(ids))
        with self.assertRaises(SystemExit):
            self.stage(proposal())

    def test_malformed_or_foreign_bundles_are_refused(self):
        bad = {
            "wrong schema": proposal(schema_version="pool_model_proposal.v0"),
            "extra field": proposal(provider_note="x"),
            "foreign pool": proposal(pool_model_id="pool/ZZZZZZZZZZZZZZZZZZZZZZ/qwen"),
            "global id": proposal(pool_model_id="qwen/qwen2.5-0.5b-instruct"),
            "two-axis pricing": proposal(pricing={"input_credits_per_million": 1, "output_credits_per_million": 1}),
        }
        missing = proposal()
        del missing["license"]
        bad["missing field"] = missing
        for label, bundle in bad.items():
            with self.subTest(label=label), self.assertRaises(SystemExit):
                self.stage(bundle)
        self.assertFalse((self.d / "model-entries.json").exists())

    def test_removing_the_last_entry_omits_the_extension(self):
        self.stage(proposal())
        self.mod.entry(types.SimpleNamespace(name="P", proposal=None, remove=proposal()["pool_model_id"],
                                             signer="coordinator-cli"))
        self.assertEqual(json.loads((self.d / "model-entries.json").read_text()), [])
        self.assertNotIn("--model-entries", self.manifest())

    def test_entries_need_the_coordinator_cli_signer(self):
        (self.d / "signer").write_text("labtool\n")
        with self.assertRaises(SystemExit):
            self.stage(proposal())


if __name__ == "__main__":
    unittest.main()
