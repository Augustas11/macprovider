import copy
import importlib.util
import hashlib
from pathlib import Path
import sys
import unittest

BASE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("lab_steps", BASE / "scripts/native_mtp_journey_lab_steps.py")
lab = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = lab
spec.loader.exec_module(lab)

class AdapterTests(unittest.TestCase):
    def fixture(self, number="10", sampled=False):
        entry = dict(source_commit="a"*40, reproducible_build_sha256="b"*64, live_executable_cdhash="c"*40,
            decode_path_digest="d"*64, metallib_sha256="e"*64, model_key="model", artifact_hash="f"*64,
            tokenizer_sha256="1"*64, qualified_slots=4, max_native_active_rows=1, max_prompt_tokens=4096,
            request_feature_profile="native_mtp_sampled_text_v1" if sampled else "native_mtp_greedy_text_v1",
            ordinary_baseline={"artifact_hash":"f"*64})
        doc = dict(schema="macprovider.native-mtp-journey-hardware-result.v1", evidence_class="lab_isolated_no_join",
            lab_binary_release_candidate=False, signed_policy_inputs=True, journey_complete=False,
            admission_tuple_sha256="2"*64, admission_sidecar_sha256="3"*64, policy_source_commit="a"*40,
            policy_binary_sha256="b"*64, policy_cdhash="c"*40, lab_decode_path_digest="d"*64,
            lab_metallib_sha256="e"*64, model_id="model", target_sha256="f"*64, mtp_sha256="f"*64,
            tokenizer_sha256="1"*64, qualified_slots=4, max_native_active_rows=1, max_prompt_tokens=4096,
            request_feature_profile=entry["request_feature_profile"], lab_binary_sha256="4"*64,
            steps=[dict(step_id=lab.RAW_IDS[number], status="pass", uncovered_contract=[],
                checks={key:True for key in lab.required_checks(number, entry)}, details={"private_path":"must not be copied"})])
        return doc, entry

    def adapt(self, doc, entry):
        return lab.adapt_record(doc, "5"*64, entry, "2"*64, "3"*64)

    def test_provenance_remains_lab_and_raw_details_not_publicly_copied(self):
        doc, entry = self.fixture()
        output = self.adapt(doc, entry)[lab.CANON["10"]]
        self.assertFalse(output["details"]["lab_binary_release_candidate"])
        self.assertEqual(output["details"]["evidence_class"], "lab_isolated_no_join")
        self.assertNotIn("private_path", str(output))

    def test_unknown_raw_check_text_is_not_copied(self):
        doc, entry = self.fixture()
        doc["steps"][0]["checks"]["private local path text"] = True
        output = self.adapt(doc, entry)
        self.assertNotIn("private local path text", str(output))

    def test_actual_failed_observation_refused(self):
        doc, entry = self.fixture()
        doc["steps"][0]["checks"]["old_request_parity"] = False
        with self.assertRaises(lab.Refusal): self.adapt(doc, entry)

    def test_missing_required_observation_refused(self):
        doc, entry = self.fixture("08")
        del doc["steps"][0]["checks"]["journey-budget-depth-zero.no_overcommit"]
        with self.assertRaises(lab.Refusal): self.adapt(doc, entry)

    def test_overall_pass_cannot_substitute_checks(self):
        doc, entry = self.fixture()
        doc["steps"][0]["checks"] = {"passed":True}
        with self.assertRaises(lab.Refusal): self.adapt(doc, entry)

    def test_ephemeral_policy_refused(self):
        doc, entry = self.fixture()
        doc["signed_policy_inputs"] = False
        with self.assertRaises(lab.Refusal): self.adapt(doc, entry)

    def test_partial_contract_refused(self):
        doc, entry = self.fixture()
        doc["steps"][0]["uncovered_contract"] = ["pending"]
        with self.assertRaises(lab.Refusal): self.adapt(doc, entry)

    def test_wrong_tuple_or_decode_path_refused(self):
        for key in ("admission_tuple_sha256", "lab_decode_path_digest", "lab_metallib_sha256", "policy_binary_sha256", "request_feature_profile"):
            doc, entry = self.fixture()
            doc[key] = "wrong"
            with self.assertRaises(lab.Refusal): self.adapt(doc, entry)

    def test_expanded_profile_must_have_all_actual_mixed_controls(self):
        doc, entry = self.fixture("07", sampled=True)
        self.adapt(doc, entry)
        del doc["steps"][0]["checks"]["journey-profile-history.native_admitted"]
        with self.assertRaises(lab.Refusal): self.adapt(doc, entry)

    def test_greedy_scope_does_not_claim_expanded_profile(self):
        doc, entry = self.fixture("07")
        self.adapt(doc, entry)
        self.assertFalse(any("journey-profile" in key for key in doc["steps"][0]["checks"]))

    def test_duplicate_steps_and_duplicate_json_keys_refused(self):
        doc, entry = self.fixture()
        doc["steps"].append(copy.deepcopy(doc["steps"][0]))
        with self.assertRaises(lab.Refusal): self.adapt(doc, entry)
        with self.assertRaises(lab.Refusal): lab.strict('{"a":1,"a":2}')

    def test_lab_hooks_are_absent_from_release_preprocessed_sources(self):
        def release_lines(text):
            active = True
            stack = []
            output = []
            for line in text.splitlines(keepends=True):
                stripped = line.strip()
                if stripped.startswith("#if "):
                    lab_guard = "DEBUG" in stripped or "MACPROVIDER_LAB_HARNESS" in stripped
                    stack.append((active, lab_guard))
                    if lab_guard: active = False
                    elif active: output.append(line)
                elif stripped == "#else":
                    parent, lab_guard = stack[-1]
                    if lab_guard: active = parent and not active
                    elif active: output.append(line)
                elif stripped == "#endif":
                    parent, lab_guard = stack.pop()
                    if not lab_guard and active: output.append(line)
                    active = parent
                elif active:
                    output.append(line)
            return "".join(output)
        # Production source evolves independently (including ordinary stop
        # metadata from main). Fence the lab hooks, rather than asserting that
        # every production byte remains a historical qualification snapshot.
        # Evidence reuse is separately enforced by source-equivalence checks.
        hooks = {
            "ModelRuntime.swift": ("labSerialDecodeHooks", "labNativeMTPCommitTimingObserver"),
            "ContinuousBatchScheduler.swift": ("labJourneyReservationContext", "labJourneyResourceObserver"),
        }
        for name, identifiers in hooks.items():
            after = (BASE / "phase3-binary/Sources/macprovider-cli" / name).read_text()
            release = release_lines(after)
            for identifier in identifiers:
                self.assertIn(identifier, after, (name, identifier))
                self.assertFalse(identifier in release, (name, identifier))

    def test_release_reservation_function_is_byte_identical(self):
        changed = (BASE / "phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift").read_text()
        start = "    private func reserveNativeMTPRoundBytes(_ bytes: Int) throws -> NativeMTPRoundByteReservation {"
        expected_sha256 = '7cd62815b81a6772b8d018c2a71c3efcd56dc3c596289277630e1c4181f4df16'
        release = changed[changed.index("    #else\n" + start)+len("    #else\n"):]
        self.assertEqual(hashlib.sha256(release[:release.index("    #endif\n")].encode()).hexdigest(), expected_sha256)

if __name__ == "__main__": unittest.main()
