#!/usr/bin/env python3
"""#1816: pool_setup.py signs pool model entries only through coordinator-cli.

A fake coordinator-cli records each sign-manifest call. The cases check that a
CLI-shaped pool_model_proposal.v1 bundle plus the creator fields becomes
exactly one R015 entry in coordinator-cli's closed --pool-models input (whose
JSON field names are read from trust_pool_sign.go), that a malformed or
foreign-pool bundle is refused, that the next manifest passes the staged file
through --pool-models and chains windows, and that removing the last entry
omits the extensions (the revocation path). testdata/pool-models.expected.json
is also loaded by the coordinator-cli signer test, so the chain
CLI bundle -> pool_setup entry -> signer input round-trips.

  python3 scripts/lab/1690-m6/test_pool_setup_model_entries.py
"""
import copy
import importlib.util
import json
import pathlib
import re
import tempfile
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent
POOL_ID = "AbCdEfGhIjKlMnOpQrStUv"
FIXTURE = json.loads((HERE / "testdata" / "pool_model_proposal.v1.json").read_text())
EXPECTED = json.loads((HERE / "testdata" / "pool-models.expected.json").read_text())
SIGNER_GO = HERE.parents[2] / "phase4-coordinator" / "cmd" / "coordinator-cli" / "trust_pool_sign.go"
CREATOR = dict(license="Apache-2.0", paid_serving_attested=True, prompt_rate=20000, cache_hit_rate=5000,
               completion_rate=40000, max_context_tokens=None)


def go_json_fields(struct):
    """The json tags of one struct in coordinator-cli's trust_pool_sign.go."""
    body = re.search(r"type " + struct + r" struct \{(.*?)\n\}", SIGNER_GO.read_text(), re.S)
    assert body, struct
    return set(re.findall(r'json:"([a-z_]+)"', body.group(1)))


def load_pool_setup(lab):
    spec = importlib.util.spec_from_file_location("pool_setup_entries_under_test", HERE / "pool_setup.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.LAB = lab
    return mod


def proposal(**entry_overrides):
    """The CLI-shaped bundle fixture, with model_entry fields overridden."""
    bundle = copy.deepcopy(FIXTURE)
    bundle["model_entry"].update(entry_overrides)
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

    def stage(self, bundle, **creator):
        path = self.lab / "bundle.json"
        path.write_text(json.dumps(bundle))
        fields = dict(CREATOR, **creator)
        self.mod.entry(types.SimpleNamespace(name="P", proposal=str(path), remove=None, attest=None, unattest=None,
                                             signer="coordinator-cli", **fields))

    def edit(self, **which):
        fields = dict(proposal=None, remove=None, attest=None, unattest=None, signer="coordinator-cli")
        fields.update(which)
        self.mod.entry(types.SimpleNamespace(name="P", **fields))

    def staged(self):
        return json.loads((self.d / "pool-models.json").read_text())

    def manifest(self):
        self.mod.manifest(types.SimpleNamespace(name="P", encoding=2, runtime_allowlist="llamacpp_loopback",
                                                settlement_mode="enforce", window_seconds=600,
                                                signer="coordinator-cli"))
        return self.cli.calls[-1]

    def test_cli_bundle_becomes_the_signer_input(self):
        self.stage(proposal())
        self.edit(attest="acct-lab-1690-member=llamacpp_loopback")
        staged = self.staged()
        self.assertEqual(staged, EXPECTED)
        # Exactly the closed coordinator-cli --pool-models schema.
        self.assertEqual(set(staged), go_json_fields("trustPoolModelsFile"))
        entry = staged["model_entries"][0]
        self.assertEqual(set(entry), go_json_fields("trustPoolModelEntryJSON"))
        self.assertEqual(set(entry["pricing"]), go_json_fields("trustPoolModelPricing"))
        self.assertEqual(set(staged["attested_members"][0]), go_json_fields("trustPoolAttestedMemberJSON"))
        # The bundle's own entry names are the signer's entry names.
        self.assertEqual(set(FIXTURE["model_entry"]), go_json_fields("trustPoolModelEntryJSON"))

    def test_proposal_rides_the_next_manifest(self):
        self.stage(proposal())
        call = self.manifest()
        self.assertEqual(call[call.index("--pool-models") + 1], str(self.d / "pool-models.json"))
        self.assertNotIn("--model-entries", call)
        self.assertEqual(call[call.index("--prev") + 1], str(self.d / "manifest-v1.json"))
        self.assertNotIn("--manifest-authority-key", call)
        # The successor starts when manifest v1 ends (labtool window rule).
        self.assertEqual(call[call.index("--not-before") + 1], self.mod.rfc3339(1600))
        self.assertEqual(call[call.index("--expires-at") + 1], self.mod.rfc3339(2200))
        self.assertEqual(json.loads((self.d / "windows.json").read_text())["2"], [1600, 2200])
        self.assertEqual(self.posted[-1]["manifest_version"], 2)

    def test_bundle_pricing_is_kept_when_the_creator_gives_none(self):
        rates = {"prompt_rate_per_mtok": 30000, "prompt_cache_hit_rate_per_mtok": 7500, "completion_rate_per_mtok": 60000}
        self.stage(proposal(pricing=rates), prompt_rate=None, cache_hit_rate=None, completion_rate=None)
        self.assertEqual(self.staged()["model_entries"][0]["pricing"], rates)

    def test_entries_stay_sorted_and_unique(self):
        self.stage(proposal(pool_model_id=f"pool/{POOL_ID}/zz-model", artifact_hash="b" * 64))
        self.stage(proposal())
        ids = [e["pool_model_id"] for e in self.staged()["model_entries"]]
        self.assertEqual(ids, sorted(ids))
        with self.assertRaises(SystemExit):
            self.stage(proposal())

    def test_malformed_or_foreign_bundles_are_refused(self):
        wrong_schema = proposal()
        wrong_schema["schema"] = "pool_model_proposal.v0"
        extra_top = proposal()
        extra_top["provider_note"] = "x"
        foreign = proposal()
        foreign["pool_id"] = "ZZZZZZZZZZZZZZZZZZZZZZ"
        missing = proposal()
        del missing["model_entry"]["license"]
        bad = {
            "wrong schema": (wrong_schema, {}),
            "extra field": (extra_top, {}),
            "foreign pool bundle": (foreign, {}),
            "foreign pool id": (proposal(pool_model_id="pool/ZZZZZZZZZZZZZZZZZZZZZZ/qwen"), {}),
            "global id": (proposal(pool_model_id="qwen/qwen2.5-0.5b-instruct"), {}),
            "missing entry field": (missing, {}),
            "two-axis pricing": (proposal(pricing={"input_credits_per_million": 1, "output_credits_per_million": 1}),
                                 dict(prompt_rate=None, cache_hit_rate=None, completion_rate=None)),
            "no pricing anywhere": (proposal(), dict(prompt_rate=None, cache_hit_rate=None, completion_rate=None)),
            "partial creator pricing": (proposal(), dict(cache_hit_rate=None)),
            "no licence": (proposal(), dict(license=None)),
            "paid serving not attested": (proposal(), dict(paid_serving_attested=False)),
            "no context": (proposal(max_context_tokens=None), {}),
        }
        for label, (bundle, creator) in bad.items():
            with self.subTest(label=label), self.assertRaises(SystemExit):
                self.stage(bundle, **creator)
        self.assertFalse((self.d / "pool-models.json").exists())

    def test_removing_the_last_entry_omits_the_extension(self):
        self.stage(proposal())
        self.edit(remove=proposal()["model_entry"]["pool_model_id"])
        self.assertEqual(self.staged(), {"model_entries": [], "attested_members": []})
        self.assertNotIn("--pool-models", self.manifest())

    def test_attested_members_alone_still_ride_the_manifest(self):
        self.edit(attest="acct-b=mlxlm_loopback,llamacpp_loopback")
        self.edit(attest="acct-a=llamacpp_loopback")
        self.assertEqual(self.staged()["attested_members"], [
            {"provider_account_id": "acct-a", "runtime_classes": ["llamacpp_loopback"]},
            {"provider_account_id": "acct-b", "runtime_classes": ["llamacpp_loopback", "mlxlm_loopback"]},
        ])
        self.assertIn("--pool-models", self.manifest())
        self.edit(unattest="acct-a")
        self.edit(unattest="acct-b")
        with self.assertRaises(SystemExit):
            self.edit(unattest="acct-b")
        self.assertNotIn("--pool-models", self.manifest())

    def test_entries_need_the_coordinator_cli_signer(self):
        (self.d / "signer").write_text("labtool\n")
        with self.assertRaises(SystemExit):
            self.stage(proposal())


if __name__ == "__main__":
    unittest.main()
