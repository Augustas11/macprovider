"""scripts/lab/ablit-perf/job-qwen-mtp-cap.sh (#2429): the formal-matrix block count and the
preregistered SPEC-048 MTP-15 exclusion rule knobs, and the launcher forwarding them."""

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / "scripts" / "lab" / "ablit-perf"
JOB = LAB / "job-qwen-mtp-cap.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"
sys.path.insert(0, str(ROOT))
import scripts.native_mtp_r015_analyze as analyzer  # noqa: E402


def policy_program() -> str:
    """The job's policy generator: its first `<<'PY'` heredoc."""
    text = JOB.read_text("utf-8")
    match = re.search(r"<<'PY' \|\| \{ blocker \"model \$k: policy generation failed\"; return 1; \}\n(.*?)\nPY\n", text, re.S)
    assert match, "policy heredoc not found"
    return match.group(1)


def generate(formal: str, blocks: str, exclusion: str) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "policy.json"
        args = [
            str(out), "qwen/qwen3.8-27b", "1" * 64, "2" * 64, "3" * 64, "4", "1536,4096,32768", "128,512",
            blocks, "Mac15,14", "25A1", "17A1", "Apple Swift version 6.2", "a" * 40, "b" * 40, "plain_text",
            formal, exclusion,
        ]
        subprocess.run([sys.executable, "-I", "-", *args], input=policy_program(), text=True, check=True)
        return json.loads(out.read_text("utf-8"))


def run_job(**env) -> subprocess.CompletedProcess:
    base = {"HOME": tempfile.gettempdir(), "COMMIT": "a" * 40}
    return subprocess.run(["bash", str(JOB)], env={**base, **env}, capture_output=True, text=True, timeout=30)


class QwenMTPCapJobTests(unittest.TestCase):
    def test_formal_policy_freezes_the_exclusion_rule_and_block_count(self):
        policy = generate("1", "11", "single_token_identical_pair")
        self.assertEqual(policy["exclusion_rules"], "single_token_identical_pair")
        self.assertEqual(policy["blocks"], 11)
        self.assertEqual(policy["schema"], analyzer.ADMISSION_POLICY_SCHEMA)
        self.assertEqual(analyzer._policy_contract_violations(policy), [])
        self.assertEqual(analyzer._matrix_violations(policy), [])

    def test_default_policy_is_unchanged(self):
        policy = generate("1", "10", "none")
        self.assertEqual((policy["exclusion_rules"], policy["blocks"]), ("none", 10))
        self.assertEqual(analyzer._matrix_violations(policy), [])

    def test_job_refuses_unknown_knob_values_before_touching_the_machine(self):
        for env, message in (
            ({"QMTP_EXCLUSION": "all"}, "QMTP_EXCLUSION must be"),
            ({"QMTP_FORMAL_BLOCKS": "9"}, "QMTP_FORMAL_BLOCKS must be 10..20"),
            ({"QMTP_FORMAL_BLOCKS": "21"}, "QMTP_FORMAL_BLOCKS must be 10..20"),
        ):
            with self.subTest(env=env):
                result = run_job(**env)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn(message, result.stdout)

    def test_formal_mode_uses_the_formal_block_count(self):
        text = JOB.read_text("utf-8")
        self.assertIn("QMTP_BLOCKS=$QMTP_FORMAL_BLOCKS; QMTP_SHAPE=plain_text", text)
        self.assertIn('"exclusion_rules": exclusion,', text)

    def test_launcher_forwards_the_knobs(self):
        text = LAUNCHER.read_text("utf-8")
        self.assertIn("|QMTP_FORMAL_BLOCKS|QMTP_EXCLUSION|", text)


if __name__ == "__main__":
    unittest.main()
