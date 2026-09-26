import contextlib
import copy
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("revenue_benchmark_workload", SCRIPTS / "revenue_benchmark_workload.py")
workload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workload)

CANDIDATES = [{"candidate_id": "incumbent", "model": "m/incumbent"},
              {"candidate_id": "challenger", "model": "m/challenger"}]


class WorkloadDefinitionTests(unittest.TestCase):
    def setUp(self):
        self.doc = workload.load(1)

    def test_v1_is_pinned_and_loads(self):
        self.assertEqual(workload.identity(self.doc), {
            "workload_id": "coding-agent-revenue",
            "version": 1,
            "sha256": workload.PINNED_SHA256[1],
        })

    def test_v1_has_long_completion_cases(self):
        long_cases = [c for c in self.doc["cases"] if c["min_completion_tokens"] >= 512]
        self.assertGreaterEqual(len(long_cases), 3)
        self.assertTrue(any(c["min_completion_tokens"] >= 1024 for c in long_cases))
        for case in self.doc["cases"]:
            self.assertGreaterEqual(case["max_tokens"], case["min_completion_tokens"])

    def test_v1_is_non_streaming_and_deterministic(self):
        for case in self.doc["cases"]:
            self.assertIs(case["stream"], False)
            self.assertEqual(case["temperature"], 0)

    def test_editing_pinned_version_fails_closed(self):
        edited = copy.deepcopy(self.doc)
        edited["cases"][0]["max_tokens"] += 1
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "edited.json")
            path.write_text(json.dumps(edited))
            with self.assertRaisesRegex(ValueError, "does not match pin"):
                workload.load(1, path)

    def test_unpinned_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not pinned"):
            workload.load(99)

    def test_validation_rejects_streaming_and_short_long_case_set(self):
        streaming = copy.deepcopy(self.doc)
        streaming["cases"][0]["stream"] = True
        with self.assertRaisesRegex(ValueError, "non-streaming"):
            workload.validate(streaming)
        short = copy.deepcopy(self.doc)
        for case in short["cases"]:
            case["min_completion_tokens"] = min(case["min_completion_tokens"], 256)
        with self.assertRaisesRegex(ValueError, "512\\+ completion floor"):
            workload.validate(short)

    def test_plan_gives_every_candidate_the_same_cases(self):
        rows = workload.plan(self.doc, "rb-test-0001", CANDIDATES, repetitions=2)
        self.assertEqual(len(rows), 2 * 2 * len(self.doc["cases"]))
        by_candidate = {}
        for row in rows:
            by_candidate.setdefault(row["candidate_id"], []).append((row["case_id"], row["repetition"]))
            self.assertEqual(row["headers"]["X-Request-ID"], row["request_id"])
            self.assertEqual(row["body"]["model"], next(c["model"] for c in CANDIDATES if c["candidate_id"] == row["candidate_id"]))
            self.assertFalse(row["body"]["stream"])
            self.assertEqual(row["workload"], workload.identity(self.doc))
        self.assertEqual(by_candidate["incumbent"], by_candidate["challenger"])

    def test_request_ids_are_unique_stable_and_run_scoped(self):
        first = workload.plan(self.doc, "rb-test-0001", CANDIDATES)
        again = workload.plan(self.doc, "rb-test-0001", CANDIDATES)
        other = workload.plan(self.doc, "rb-test-0002", CANDIDATES)
        ids = [r["request_id"] for r in first]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(ids, [r["request_id"] for r in again])
        self.assertFalse(set(ids) & {r["request_id"] for r in other})

    def test_plan_rejects_bad_run_and_candidate_ids(self):
        with self.assertRaises(ValueError):
            workload.plan(self.doc, "BAD", CANDIDATES)
        with self.assertRaises(ValueError):
            workload.plan(self.doc, "rb-test-0001", CANDIDATES + [CANDIDATES[0]])

    def test_cli_plan_emits_jsonl_without_sending(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            workload.main(["plan", "--run-id", "rb-test-0001", "--candidate", "incumbent=m/incumbent"])
        rows = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([r["case_id"] for r in rows], [c["case_id"] for c in self.doc["cases"]])


if __name__ == "__main__":
    unittest.main()
