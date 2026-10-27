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


class FullyQualifiedPredecessorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.stage, self.bundle = root / "source", root / "bundle"
        self.bundle.mkdir()
        self.cat = self.stage / m.CATALOG
        self.static = self.stage / m.STATIC
        self.cat.mkdir(parents=True); self.static.mkdir(parents=True)
        for name in m.RELEASE_FILES:
            target = self.cat if name in {"release.json", "trusted-keys.json", "tier2-catalog.json"} else self.static
            (target / name).write_bytes(m.canonical({"committed_asset": name}))
        (self.cat / "release-ledger.json").write_bytes(b"committed ledger\n")
        self.commit = "c" * 40
        self.identity = {"provider_revision": self.commit, "source_commit": self.commit,
                         "reproducible_build_sha256": "a" * 64, "live_executable_cdhash": "b" * 40,
                         "metallib_sha256": "d" * 64}
        self.inputs = {"schema_version": "macprovider.native-mtp-binding-input.v1",
                       "phase": "expanded_glm_sampled", "release_id": "qualified-published-candidate",
                       "generated_at": "2026-10-27T00:00:00Z", "candidate_version": "1.8.277",
                       "identity": self.identity, "parent_receipt_sha256": None}
        self.bounds = {"request_feature_profile": "native_mtp_sampled_text_v1", "proposal_depth": 1,
                       "max_native_active_rows": 1, "max_prompt_tokens": 4096, "qualified_slots": 4}
        self.recipe = {"source_inputs": {}, "model_key": "zai-org/glm-5.3-flash",
                       "phases": {"expanded_glm_sampled": self.bounds}}
        self.entry = dict(self.bounds, model_key=self.recipe["model_key"])
        (self.cat / "native-mtp-admission-release.json").write_bytes(m.canonical({"entry": {}, "signer_key_id": "fixture"}))
        (self.cat / "native-mtp-admission-tuple.json").write_bytes(m.canonical([{"entry": self.entry}]))
        m._flat(self.stage, self.bundle / "previous")

    def prepare(self):
        m._prepare_predecessor(self.bundle, repo=Path("."), commit=self.commit,
                               stage=self.stage, inputs=self.inputs)

    def derive(self):
        (self.bundle / "inputs.json").write_bytes(m.canonical(self.inputs))
        self.calls = []
        dp = mock.Mock()
        dp.compute.return_value = "e" * 64
        dp.resolved_revisions.return_value = {"mlx-swift-lm": "f" * 40}
        with mock.patch.object(m, "_module", return_value=dp), \
             mock.patch.object(m, "_environment", return_value={}), \
             mock.patch.object(m, "_run", side_effect=lambda args, **kwargs: self.calls.append(args)) as run, \
             mock.patch.object(m, "git", return_value=(self.cat / "tier2-catalog.json").read_bytes()):
            m._derive(self.bundle, repo=Path("."), commit=self.commit,
                      recipe=self.recipe, stage=self.stage, sign=True)
        return run

    def test_fresh_qualified_path_retains_committed_ledger(self):
        with mock.patch.object(m, "verify_bundle") as parent:
            self.prepare()
            parent.assert_not_called()
        self.assertEqual((self.cat / "release-ledger.json").read_bytes(), b"committed ledger\n")

    def test_fresh_qualified_path_still_requires_full_qualification_before_generate(self):
        def qualified(*args, **kwargs):
            self.calls.append(["qualification"])
            return {"correctness_evidence_sha256": "1" * 64}
        with mock.patch.object(m, "_qualification", side_effect=qualified) as qualification:
            run = self.derive()
        qualification.assert_called_once()
        generated = next(index for index, command in enumerate(self.calls) if "generate" in command)
        self.assertLess(self.calls.index(["qualification"]), generated)
        derived = m.read_json(self.cat / "native-mtp-admission-tuple.json")[0]["entry"]
        self.assertEqual(derived["correctness_evidence_sha256"], "1" * 64)
        self.assertEqual((self.cat / "release-ledger.json").read_bytes(), b"committed ledger\n")

    def test_fresh_qualified_path_rejects_any_predecessor_byte_change(self):
        previous = self.bundle / "previous"
        for name in sorted(m.RELEASE_FILES):
            original = (previous / name).read_bytes()
            (previous / name).write_bytes(original + b" ")
            with self.subTest(name=name), self.assertRaisesRegex(m.BindingBundleError, "differs from committed release"):
                self.prepare()
            (previous / name).write_bytes(original)

    def test_fresh_qualified_path_rejects_extra_predecessor_member(self):
        (self.bundle / "previous" / "unreviewed.json").write_text("{}")
        with self.assertRaisesRegex(m.BindingBundleError, "differs from committed release"):
            self.prepare()

    def test_nonnull_receipt_without_parent_cannot_use_fresh_path(self):
        self.inputs["parent_receipt_sha256"] = "a" * 64
        with self.assertRaisesRegex(m.BindingBundleError, "receipt requires verified parent"):
            self.prepare()

    def test_null_receipt_rejects_orphan_parent_or_dangling_symlink(self):
        parent = self.bundle / "parent"
        parent.mkdir()
        with self.assertRaisesRegex(m.BindingBundleError, "orphan parent"):
            self.prepare()
        parent.rmdir(); parent.symlink_to(self.bundle / "missing-parent")
        with self.assertRaisesRegex(m.BindingBundleError, "orphan parent"):
            self.prepare()

    def test_exact_greedy_parent_route_is_preserved(self):
        parent_path = self.bundle / "parent"; parent_path.mkdir()
        (parent_path / "inputs.json").write_bytes(m.canonical(self.inputs))
        ledger = parent_path / "ledger.json"; ledger.write_bytes(b"verified parent ledger\n")
        self.inputs["parent_receipt_sha256"] = "a" * 64
        parent = mock.Mock(phase="identity_only_greedy", receipt_sha256="a" * 64,
                           release_dir=self.bundle / "previous", ledger_path=ledger)
        with mock.patch.object(m, "verify_bundle", return_value=parent) as verify:
            self.prepare()
        verify.assert_called_once_with(parent_path, repo=Path("."), commit=self.commit, recipe_path=m.RECIPE_PATH)
        self.assertEqual((self.cat / "release-ledger.json").read_bytes(), b"verified parent ledger\n")

    def test_parent_route_still_requires_exact_signed_candidate_identity(self):
        parent_path = self.bundle / "parent"; parent_path.mkdir()
        different = copy.deepcopy(self.inputs)
        different["identity"]["reproducible_build_sha256"] = "0" * 64
        (parent_path / "inputs.json").write_bytes(m.canonical(different))
        self.inputs["parent_receipt_sha256"] = "a" * 64
        parent = mock.Mock(phase="identity_only_greedy", receipt_sha256="a" * 64,
                           release_dir=self.bundle / "previous")
        with mock.patch.object(m, "verify_bundle", return_value=parent), \
             self.assertRaisesRegex(m.BindingBundleError, "retain exact signed CLI identity"):
            self.prepare()

    def test_fresh_path_without_numerical_qualification_stops_before_generation(self):
        with self.assertRaisesRegex(m.BindingBundleError, "regular JSON file required"):
            self.derive()
        self.assertTrue(any("restamp" in command for command in self.calls))
        self.assertFalse(any("generate" in command for command in self.calls))

    def test_fresh_path_wrong_signed_measurement_identity_is_not_qualified(self):
        q = self.bundle / "qualification"; q.mkdir()
        for name in ("acceptance-policy.json", "acceptance-corpus.json"):
            (q / name).write_bytes(m.canonical({}))
        (q / "acceptance.json").write_bytes(m.canonical({"measurement_identity": {
            "binary_sha256": "0" * 64, "binary_cdhash": self.identity["live_executable_cdhash"]}}))
        with self.assertRaisesRegex(m.BindingBundleError, "regular JSON file required"):
            self.derive()


class SignedMeasurementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.q = Path(self.temp.name)
        self.identity = {"source_commit": "c" * 40, "reproducible_build_sha256": "a" * 64,
                         "live_executable_cdhash": "b" * 40}
        self.measured = {"binary_sha256": "a" * 64, "binary_cdhash": "b" * 40}
        self.entry = {"model_key": "zai-org/glm-5.3-flash", "ordinary_baseline": {"artifact_hash": "d" * 64},
                      "artifact_hash": "d" * 64, "tokenizer_sha256": "e" * 64,
                      "runtime_revision": "f" * 40, "qualified_slots": 4, "max_native_active_rows": 1,
                      "proposal_depth": 1, "max_prompt_tokens": 4096}
        self.policy = {"schema": "macprovider.native-mtp-r015-policy.v1", "provider_commit": "c" * 40,
                       "model_id": self.entry["model_key"], "target_sha256": "d" * 64,
                       "mtp_sha256": "d" * 64, "tokenizer_sha256": "e" * 64,
                       "mlx_fork_revision": "f" * 40, "qualified_slots": 4, "max_native_active_rows": 1,
                       "proposal_depth": 1, "maximum_prompt_tokens": 4096}
        self.header = {"provider_commit": "c" * 40, "measurement_identity": copy.deepcopy(self.measured)}
        self.runs = [{"sustained": sustained, "measurement_identity": copy.deepcopy(self.measured)}
                     for sustained in (False, True)]
        self.analyzer = mock.Mock()
        self.analyzer.analyze.return_value = {"overall_status": "PASS", "cells": ["actual rederived cells"]}
        (self.q / "bench-analysis.json").write_bytes(m.canonical(self.analyzer.analyze.return_value))

    def check_bench(self):
        (self.q / "bench-policy.json").write_bytes(m.canonical(self.policy))
        self.analyzer._load_jsonl.return_value = (self.header, self.runs)
        with mock.patch.object(m, "_module", return_value=self.analyzer):
            m.validate_formal_bench(self.q, stage=Path("."), entry=self.entry, identity=self.identity)

    def test_formal_matrix_and_sustained_reopen_the_analyzer(self):
        self.check_bench()
        self.analyzer.analyze.assert_called_once_with(self.q / "bench.jsonl", self.q / "bench-policy.json")

    def test_missing_runtime_identity_cannot_be_replaced_by_source_identity(self):
        with self.assertRaisesRegex(m.BindingBundleError, "signed measurement executable"):
            m.validate_measurement_identity({"source_commit": "c" * 40}, self.identity, label="R005")

    def test_source_equivalent_lab_sha_or_cdhash_rejected(self):
        for field in ("binary_sha256", "binary_cdhash"):
            measured = dict(self.measured); measured[field] = "0" * len(measured[field])
            with self.subTest(field=field), self.assertRaisesRegex(m.BindingBundleError, "signed measurement executable"):
                m.validate_measurement_identity({"measurement_identity": measured}, self.identity, label="R005")

    def test_identity_is_an_exact_object(self):
        for value in (None, [], dict(self.measured, source_commit="c" * 40)):
            with self.subTest(value=value), self.assertRaisesRegex(m.BindingBundleError, "signed measurement executable"):
                m.validate_measurement_identity({"measurement_identity": value}, self.identity, label="replay")

    def test_each_matrix_and_sustained_run_requires_current_executable(self):
        for index in range(2):
            original = self.runs[index].pop("measurement_identity")
            with self.subTest(index=index), self.assertRaisesRegex(m.BindingBundleError, "R015 run signed measurement"):
                self.check_bench()
            self.runs[index]["measurement_identity"] = original
        self.analyzer.analyze.assert_not_called()

    def test_sustained_from_a_different_binary_is_rejected(self):
        self.runs[1]["measurement_identity"]["binary_cdhash"] = "0" * 40
        with self.assertRaisesRegex(m.BindingBundleError, "R015 run signed measurement"):
            self.check_bench()

    def test_header_from_a_different_binary_is_rejected(self):
        self.header["measurement_identity"]["binary_sha256"] = "0" * 64
        with self.assertRaisesRegex(m.BindingBundleError, "R015 header signed measurement"):
            self.check_bench()

    def test_same_binary_record_cannot_claim_other_source(self):
        for record in (self.policy, self.header):
            record["provider_commit"] = "0" * 40
            with self.assertRaisesRegex(m.BindingBundleError, "candidate source mismatch"):
                self.check_bench()
            record["provider_commit"] = "c" * 40

    def test_exploratory_policy_is_not_formal_qualification(self):
        self.policy["schema"] = "macprovider.native-mtp-exploratory-policy.v1"
        with self.assertRaisesRegex(m.BindingBundleError, "formal R015 policy required"):
            self.check_bench()

    def test_tuple_or_artifact_substitution_fails(self):
        self.policy["max_native_active_rows"] = 2
        with self.assertRaisesRegex(m.BindingBundleError, "tuple/artifact binding"):
            self.check_bench()

    def test_sustained_is_required_even_if_summary_claims_pass(self):
        self.runs.pop()
        with self.assertRaisesRegex(m.BindingBundleError, "sustained records required"):
            self.check_bench()

    def test_actual_analyzer_failure_beats_supplied_pass(self):
        self.analyzer.analyze.return_value = {"overall_status": "FAIL"}
        with self.assertRaisesRegex(m.BindingBundleError, "analyzer gate failed"):
            self.check_bench()

    def test_supplied_analysis_must_equal_recomputed_result(self):
        (self.q / "bench-analysis.json").write_bytes(m.canonical({"overall_status": "PASS"}))
        with self.assertRaisesRegex(m.BindingBundleError, "not the rederived result"):
            self.check_bench()

    def test_r005_unbound_runtime_identity_rejected_before_numerical_validation(self):
        (self.q / "qualification").mkdir()
        (self.q / "inputs.json").write_bytes(m.canonical({"identity": self.identity}))
        for name in ("acceptance.json", "acceptance-policy.json", "acceptance-corpus.json"):
            (self.q / "qualification" / name).write_bytes(m.canonical({}))
        with mock.patch.object(m, "validate_acceptance") as numerical:
            with self.assertRaisesRegex(m.BindingBundleError, "regular JSON file required"):
                m._qualification(Path("."), self.q, self.entry, {}, repo=Path("."))
            numerical.assert_not_called()


class LabQualificationIdentityTests(unittest.TestCase):
    def identity(self):
        return {"source_commit": "c" * 40, "decode_path_digest": "d" * 64,
                "measurement_identity": {"binary_sha256": "a" * 64, "binary_cdhash": None,
                                         "decode_path_digest": "d" * 64}}

    def test_lab_archive_binds_identity_without_rewriting_old_raw_records(self):
        identity = self.identity()
        m.validate_measurement_identity({}, identity, label="LAB")
        m.validate_measurement_identity({"measurement_identity": identity["measurement_identity"]}, identity, label="LAB")

    def test_digest_mismatch_or_foreign_runtime_is_rejected(self):
        identity = self.identity()
        for field, bad in (("binary_sha256", "bad"), ("binary_cdhash", "bad"), ("decode_path_digest", "f" * 64)):
            changed = copy.deepcopy(identity); changed["measurement_identity"][field] = bad
            with self.subTest(field=field), self.assertRaises(m.BindingBundleError):
                m.validate_measurement_identity({}, changed, label="LAB")
        with self.assertRaises(m.BindingBundleError):
            m.validate_measurement_identity({"measurement_identity": {"binary_sha256": "e" * 64}}, identity, label="LAB")

    def test_formal_lab_matrix_is_independent_of_later_signed_binary(self):
        fixture = SignedMeasurementTests(); fixture.setUp()
        try:
            fixture.identity = self.identity()
            fixture.header.pop("measurement_identity")
            for run in fixture.runs: run.pop("measurement_identity")
            fixture.check_bench()
            fixture.analyzer.analyze.assert_called_once()
        finally:
            fixture.doCleanups()


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
