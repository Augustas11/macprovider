"""The renewal script's post-SIGHUP activation check must be runnable Python.

`scripts/renew-autotune-static-feed.sh --deploy` proves the coordinator
reloaded THIS release by comparing the served `generated_at` to the run's
stamp with an inline `python3 -c` block. On 2026-09-16 that block carried a
backslash-escaped quote inside an f-string and raised SyntaxError, which the
script could only read as "did not activate" and rolled back a good reload.
This test executes the exact block the script ships, so a quoting regression
fails here instead of on Pearl.
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "renew-autotune-static-feed.sh"


def served_check_source() -> str:
    text = SCRIPT.read_text(encoding="utf-8")
    match = re.search(
        r"""printf '%s' "\$SERVED_JSON" \| python3 -c '\n(?P<body>.*?)\n' "\$NOW_ISO"; then""",
        text,
        re.S,
    )
    if match is None:
        raise AssertionError("served-feed activation check block not found in renew-autotune-static-feed.sh")
    body = match.group("body")
    if "\\" in body:
        raise AssertionError("activation check must not contain backslashes (bash single quotes pass them to python verbatim)")
    if "'" in body:
        raise AssertionError("activation check must not contain single quotes (it is embedded in a bash single-quoted string)")
    return body


def run_check(body: str, served: dict, expected: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-c", body, expected],
        input=json.dumps(served),
        capture_output=True,
        text=True,
        check=False,
    )


class RenewServedFeedCheckTest(unittest.TestCase):
    def test_block_is_valid_python(self) -> None:
        compile(served_check_source(), "<renew-autotune-static-feed.sh served check>", "exec")

    def test_exact_stamp_passes(self) -> None:
        body = served_check_source()
        result = run_check(body, {"generated_at": "2026-09-16T10:08:56Z"}, "2026-09-16T10:08:56Z")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-> OK", result.stderr)

    def test_other_stamp_fails_closed(self) -> None:
        body = served_check_source()
        result = run_check(body, {"generated_at": "2026-09-02T00:00:00Z"}, "2026-09-16T10:08:56Z")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("-> MISMATCH", result.stderr)

    def test_missing_stamp_fails_closed(self) -> None:
        body = served_check_source()
        result = run_check(body, {"version": "x"}, "2026-09-16T10:08:56Z")
        self.assertEqual(result.returncode, 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
