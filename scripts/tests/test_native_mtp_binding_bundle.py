"""Bounded model-free recipe/oracle tests; mocked API replies are not live proof."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_mtp_binding_bundle", HERE / "native_mtp_binding_bundle.py")
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)


class CommittedRecipeTests(unittest.TestCase):
    def setUp(self):
        self.repo = HERE.parent
        self.recipe = json.loads((self.repo / m.RECIPE_PATH).read_text())

    def test_frozen_source_inputs_match_the_reviewed_tree(self):
        for relative, expected in self.recipe["source_inputs"].items():
            with self.subTest(path=relative):
                self.assertEqual(m.digest(self.repo / relative), expected)

    def test_required_security_cases_exist_and_policy_bounds_stay_one(self):
        test_root = self.repo / "phase3-binary/Tests/macprovider-cliTests"
        for case in self.recipe["security_required_cases"]:
            cls, method = case.split(".")
            with self.subTest(case=case):
                source = (test_root / (cls + ".swift")).read_text()
                self.assertRegex(source, rf"\bclass\s+{re.escape(cls)}\s*:")
                self.assertRegex(source, rf"\bfunc\s+{re.escape(method)}\s*\(")
        for phase, bounds in self.recipe["phases"].items():
            with self.subTest(phase=phase):
                self.assertEqual(bounds["max_native_active_rows"], 1)
                self.assertEqual(bounds["proposal_depth"], 1)
                self.assertEqual(bounds["qualified_slots"], 4)


class BindingCoreTests(unittest.TestCase):
    def fixture(self):
        entry = dict(model_key="zai-org/glm-5.3-flash", artifact_hash="a" * 64,
                     tokenizer_sha256="b" * 64, ordinary_baseline={"artifact_hash": "a" * 64},
                     qualified_slots=4, max_native_active_rows=1, proposal_depth=1, max_prompt_tokens=4096)
        policy = dict(schema="macprovider.native-mtp-acceptance-policy.v1", model_id=entry["model_key"],
                      target_sha256="a" * 64, mtp_sha256="a" * 64, tokenizer_sha256="b" * 64,
                      provider_commit="c" * 40, corpus_sha256="d" * 64)
        corpus = {"cases": []}
        result = dict(schema="macprovider.native-mtp-acceptance-result.v1", status="pass",
                      evidence_class="lab_isolated_no_join", policy_sha256="e" * 64,
                      corpus_sha256="d" * 64, checks={key: True for key in (
                          "all_cases_passed", "native_positions", "all_and_none_acceptance",
                          "partial_acceptance_inapplicable", "eos_terminal", "stop_sequence_terminal",
                          "max_tokens_terminal", "generated_tool_boundary", "generated_reasoning_close", "near_tied_positions")},
                      native_compared_positions=6400, cases=[])
        for key in ("model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256", "provider_commit"):
            result[key] = policy[key]
        for key in ("qualified_slots", "max_native_active_rows", "proposal_depth", "max_prompt_tokens"):
            result[key] = entry[key]
        for index in range(200):
            stratum = ("short", "1.5k", "4k", "8k", "near_boundary")[index % 5]
            expected_native = stratum != "8k"
            corpus["cases"].append({"id": str(index), "stratum": stratum, "expected_native": expected_native})
            positions = [dict(position=p, ordinary_token=p, native_token=p, token_exact=True, top1_exact=True,
                              finite=True, max_abs_difference=0.025, ordinary_top1=p, native_top1=p,
                              ordinary_gap=0.04, native_gap=0.04) for p in range(40)]
            selected = copy.deepcopy(positions)
            if index == 0:
                selected.append(dict(selected[-1], position=40, ordinary_token=99, native_token=99))
            result["cases"].append(dict(id=str(index), stratum=stratum, passed=True, prompt_stratum_passed=True,
                                        expected_native=expected_native, admission_passed=True, output_parity=True,
                                        oracle_failure=None, ordinary_terminal="eos", native_terminal="eos",
                                        completion_tokens=40, ordinary_selected_count=len(selected), native_selected_count=len(selected),
                                        positions=positions, selected_positions=selected))
        return result, policy, corpus, entry

    def validate(self, result, policy, corpus, entry):
        return m.validate_acceptance(result, policy, corpus, entry, policy_sha="e" * 64, corpus_sha="d" * 64)

    def test_full_numeric_records_include_withheld_terminal(self):
        self.validate(*self.fixture())

    def test_same_terminal_cause_different_selected_eos_fails(self):
        data = self.fixture(); data[0]["cases"][0]["selected_positions"][-1]["native_token"] = 100
        with self.assertRaisesRegex(m.BindingBundleError, "token/top1"): self.validate(*data)

    def test_selected_count_cannot_hide_terminal(self):
        data = self.fixture(); data[0]["cases"][0]["native_selected_count"] -= 1
        with self.assertRaisesRegex(m.BindingBundleError, "selected count"): self.validate(*data)

    def test_numeric_tolerance_is_not_relaxed(self):
        data = self.fixture(); data[0]["cases"][0]["selected_positions"][-1]["max_abs_difference"] = 0.050001
        with self.assertRaisesRegex(m.BindingBundleError, "numeric tolerance"): self.validate(*data)

    def test_nonfinite_numeric_record_fails(self):
        data = self.fixture(); data[0]["cases"][0]["positions"][0]["ordinary_gap"] = float("nan")
        with self.assertRaisesRegex(m.BindingBundleError, "nonfinite"): self.validate(*data)

    def test_incomplete_corpus_fails(self):
        data = self.fixture(); data[0]["cases"].pop()
        with self.assertRaisesRegex(m.BindingBundleError, "incomplete"): self.validate(*data)

    def test_duplicate_case_fails(self):
        data = self.fixture(); data[0]["cases"][1]["id"] = "0"
        with self.assertRaisesRegex(m.BindingBundleError, "identity/order"): self.validate(*data)

    def test_ordinary_fallback_does_not_count_toward_native_floor(self):
        data = self.fixture(); data[0]["cases"][0]["expected_native"] = False
        with self.assertRaises(m.BindingBundleError): self.validate(*data)

    def test_all_pass_boolean_is_insufficient(self):
        with self.assertRaises(m.BindingBundleError): self.validate({"passed": True}, {}, {}, {})

    def test_profile_cannot_change_cb_rows(self):
        data = self.fixture(); data[0]["qualified_slots"] = 1
        with self.assertRaisesRegex(m.BindingBundleError, "tuple bounds"): self.validate(*data)

    def test_missing_numeric_terminal_record_fails(self):
        data = self.fixture(); data[0]["cases"][0]["selected_positions"] = []
        with self.assertRaisesRegex(m.BindingBundleError, "selected positions"): self.validate(*data)

    def test_expanded_binding_requires_actual_signed_serving_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp) / "source"
            release = stage / m.CATALOG / "native-mtp-admission-release.json"
            release.parent.mkdir(parents=True)
            release.write_text("{}")
            dp = mock.Mock()
            dp.verify_release_input.return_value = "1.8.274"
            dp._tag_commit.return_value = "a" * 40
            serving = mock.Mock()
            serving.verify_serving_proof.side_effect = ValueError("signed serving proof absent")
            def module(_, name):
                return serving if name == "native_mtp_signed_serving_proof.py" else dp
            with mock.patch.object(m, "_module", side_effect=module), mock.patch.dict(m.os.environ, {"BINDING_REPO_INTERNAL": tmp}):
                with self.assertRaisesRegex(ValueError, "signed serving proof absent"):
                    m._candidate_gate(stage, Path(tmp) / "bundle", {"phase": "expanded_glm_sampled", "candidate_version": "1.8.274", "identity": {"source_commit": "a" * 40}})
            serving.verify_serving_proof.assert_called_once_with(Path(tmp) / "bundle/proof/serving-journey", Path(tmp), "a" * 40, stage / m.STATIC / "native-mtp-admission.json")

    def test_duplicate_json_keys_fail(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.json"; p.write_text('{"source":1,"source":2}')
            with self.assertRaisesRegex(m.BindingBundleError, "duplicate"): m.read_json(p)

    def test_symlink_inventory_fails(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root / "target").write_text("x"); (root / "link").symlink_to(root / "target")
            with self.assertRaisesRegex(m.BindingBundleError, "symlinks"): m.inventory(root)

    def test_wrong_recipe_is_rejected_before_git(self):
        with mock.patch.object(m, "git") as git:
            with self.assertRaisesRegex(m.BindingBundleError, "only the reviewed"): m._recipe(Path("."), "a"*40, "arbitrary.json")
            git.assert_not_called()

    def test_archive_rejects_option_injection_before_git(self):
        with mock.patch.object(m, "git") as git:
            with self.assertRaisesRegex(m.BindingBundleError, "full source"): m._archive(Path("."), "--output=/tmp/no", Path("/tmp/no"))
            git.assert_not_called()


class SecurityArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.q = Path(self.temp.name); self.sha = "c" * 40
        self.recipe = {"security_artifact_name": "swift-xunit-shard-{shard}-{sha}", "security_required_cases": ["ScopeTests.testRejectsSampledGrammar", "ScopeTests.testRejectsExtraRow"]}
        self.run = dict(id=17, head_sha=self.sha, status="completed", conclusion="success", path=".github/workflows/ci.yml", repository={"full_name":"Augustas11/macprovider"})
        self.metadata = {}; items=[]; reports={}
        for shard in range(1,5):
            name = "testRejectsSampledGrammar" if shard == 1 else "testRejectsExtraRow" if shard == 2 else f"testOther{shard}"
            report=f'<testsuite><testcase classname="macprovider_cliTests.ScopeTests" name="{name}"></testcase></testsuite>'.encode()
            path = self.q / f"security-tests-{shard}.zip"
            with zipfile.ZipFile(path,"w") as archive: archive.writestr("shard-xunit.xml", report)
            sha=m.digest(path); item=dict(shard=shard,artifact_id=shard+100,artifact_sha256=sha); items.append(item)
            self.metadata[shard+100]=dict(id=shard+100,name=f"swift-xunit-shard-{shard}-{self.sha}",expired=False,digest="sha256:"+sha,workflow_run={"id":17,"head_sha":self.sha})
            reports[str(shard)]=hashlib.sha256(report).hexdigest()
        self.frozen=dict(run_id=17,source_commit=self.sha,artifacts=items)
        (self.q/"security-actions.json").write_bytes(m.canonical(self.frozen))
        lanes={}
        for lane in ("code","security","architecture"):
            p=self.q/f"audit-{lane}.md";p.write_text("Actual fixture audit lane record; no findings.\n")
            lanes[lane]={"record_sha256":m.digest(p),"findings":[]}
        audit=dict(schema_version="macprovider.native-mtp-audit-record.v1",source_commit=self.sha,base_commit="b"*40,diff_sha256=hashlib.sha256(b"actual diff").hexdigest(),lanes=lanes)
        (self.q/"audit.json").write_bytes(m.canonical(audit))
        aggregate=dict(schema_version="macprovider.native-mtp-security-evidence.v1",prior_hardware_negative_evidence_sha256="d"*64,actions=self.frozen,junit_sha256_by_shard=reports,audit_sha256=m.digest(self.q/"audit.json"),audit_records={k:v["record_sha256"] for k,v in lanes.items()})
        (self.q/"security-evidence.json").write_bytes(m.canonical(aggregate))

    def check(self):
        def run(args,**kw):
            if str(args[-1]).endswith("runs/17"): return m.canonical(self.run)
            return m.canonical(self.metadata[int(str(args[-1]).split("/")[-1])])
        with mock.patch.object(m,"_run",side_effect=run),mock.patch.object(m,"git",return_value=b"actual diff"):
            return m.validate_security_artifact(self.q,repo=Path("."),source={"source_commit":self.sha},recipe=self.recipe,prior_evidence="d"*64)

    def test_actual_zip_case_union_and_three_lane_records_validate(self):
        self.assertEqual(self.check(),m.digest(self.q/"security-evidence.json"))

    def test_fresh_api_digest_mismatch_fails_despite_stored_pass(self):
        self.metadata[101]["digest"]="sha256:"+"0"*64
        with self.assertRaisesRegex(m.BindingBundleError,"authenticated Actions digest"): self.check()

    def test_fresh_api_failed_run_fails(self):
        self.run["conclusion"]="failure"
        with self.assertRaisesRegex(m.BindingBundleError,"successful security CI"): self.check()

    def test_missing_required_negative_case_fails(self):
        self.recipe["security_required_cases"].append("ScopeTests.testNeverRan")
        with self.assertRaisesRegex(m.BindingBundleError,"missing or skipped"): self.check()

    def test_audit_combined_diff_mismatch_fails(self):
        a=m.read_json(self.q/"audit.json");a["diff_sha256"]="0"*64;(self.q/"audit.json").write_bytes(m.canonical(a))
        with self.assertRaisesRegex(m.BindingBundleError,"full combined diff"): self.check()

    def test_medium_audit_finding_fails(self):
        a=m.read_json(self.q/"audit.json");a["lanes"]["security"]["findings"]=[{"id":"SEC1","severity":"MEDIUM"}];(self.q/"audit.json").write_bytes(m.canonical(a))
        with self.assertRaisesRegex(m.BindingBundleError,"zero critical/high/medium"): self.check()

if __name__ == "__main__": unittest.main()
