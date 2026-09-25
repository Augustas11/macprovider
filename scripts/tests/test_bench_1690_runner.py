"""#1690 freeze audit R1: the benchmark runner under /bin/bash (3.2 on macOS).

Covers the clean-machine pgrep/pipefail exit (CODE-7), strictly opt-in
pausing (SEC-5), and a resume that is installed before the pause, retried,
verified, and loud when it fails (SEC-5, CODE-8). Every binary the runner
calls is a stub; nothing touches a real provider.
"""

import http.server
import json
import os
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[2] / "phase3-binary" / "scripts" / "bench-1690-loopback-vs-native.sh"


class FakeProvider:
    """A control socket that records frames plus a /v1/status endpoint."""

    def __init__(self, directory, resume_works=True):
        self.frames = []
        self.paused = False
        self.resume_works = resume_works
        self.socket_path = os.path.join(directory, "control.sock")
        provider = self

        class Control(socketserver.StreamRequestHandler):
            def handle(self):
                frame = json.loads(self.rfile.readline())["type"]
                provider.frames.append(frame)
                accepted = True
                if frame == "pause_request":
                    provider.paused = True
                elif frame == "resume_request":
                    accepted = provider.resume_works and provider.paused
                    if provider.resume_works:
                        provider.paused = False
                self.wfile.write((json.dumps({"accepted": accepted}) + "\n").encode())

        class Status(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"lifecycle": {"operator_paused": provider.paused}}).encode()
                self.send_response(200)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.control = socketserver.ThreadingUnixStreamServer(self.socket_path, Control)
        self.status = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Status)
        self.port = self.status.server_address[1]
        for server in (self.control, self.status):
            threading.Thread(target=server.serve_forever, daemon=True).start()

    def close(self):
        for server in (self.control, self.status):
            server.shutdown()
            server.server_close()


@unittest.skipUnless(sys.platform == "darwin", "the runner targets a macOS lab Mac")
class Bench1690RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin = root / "bin"
        self.llama = root / "llama"
        for directory in (self.bin, self.llama):
            directory.mkdir()
        # pgrep: FAKE_SERVE_COUNT serve processes for -f, never a llama-server.
        self._stub(self.bin / "pgrep", """
if [ "$1" = "-f" ] && [ "${FAKE_SERVE_COUNT:-0}" -gt 0 ]; then
  i=0; while [ "$i" -lt "$FAKE_SERVE_COUNT" ]; do echo "$((4000 + i))"; i=$((i + 1)); done; exit 0
fi
exit 1
""")
        self._stub(self.llama / "llama-server", 'echo "version: 0 (stub)"')
        self._stub(self.llama / "llama-perplexity", "exit 0")
        self.cli = root / "macprovider-cli"
        self._stub(self.cli, """
out=""
while [ "$#" -gt 0 ]; do [ "$1" = "--output" ] && out="$2"; shift; done
[ -n "$out" ] && echo '{}' > "$out"
exit 0
""")
        for name in ("text.raw", "model.gguf"):
            (root / name).write_text("stub\n")
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": self.tmp.name,
            "CLI": str(self.cli),
            "LLAMA_DIR": str(self.llama),
            "MLX_MODEL": str(root / "mlx"),
            "GGUFS": str(root / "model.gguf"),
            "TEXT": str(root / "text.raw"),
            "OUT": str(root / "out"),
            "PAUSE_RETRY_SECONDS": "0",
            "RESUME_RETRY_SECONDS": "0",
            "RESUME_ATTEMPTS": "2",
        }

    def _stub(self, path, body):
        path.write_text("#!/bin/sh\n" + body.lstrip())
        path.chmod(0o755)

    def run_runner(self, **extra):
        env = dict(self.env)
        env.update(extra)
        return subprocess.run(["/bin/bash", str(RUNNER)], env=env, capture_output=True, text=True, timeout=120)

    def test_clean_machine_without_provider_runs(self):
        result = self.run_runner(PPL_ONLY="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("perplexity-only run done", result.stderr)

    def test_pause_variables_without_opt_in_refuse(self):
        result = self.run_runner(PAUSE_PROVIDER_SOCKET="/nonexistent.sock", PAUSE_PROVIDER_PORT="1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("refusing to pause a live provider implicitly", result.stderr)

    def test_ppl_only_never_pauses(self):
        result = self.run_runner(PPL_ONLY="1", PAUSE_PROVIDER="1", PAUSE_PROVIDER_SOCKET="/x", PAUSE_PROVIDER_PORT="1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("PPL_ONLY=1 never pauses", result.stderr)

    def test_failure_after_pause_resumes_and_verifies(self):
        provider = FakeProvider(self.tmp.name)
        self.addCleanup(provider.close)
        # Two serve processes: the runner refuses (exit 3) after pausing.
        result = self.run_runner(
            PAUSE_PROVIDER="1",
            PAUSE_PROVIDER_SOCKET=provider.socket_path,
            PAUSE_PROVIDER_PORT=str(provider.port),
            FAKE_SERVE_COUNT="2",
        )
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("PAUSING the live provider", result.stderr)
        self.assertEqual(provider.frames, ["pause_request", "resume_request"])
        self.assertFalse(provider.paused)
        self.assertIn("resumed", result.stderr)

    def test_failed_resume_is_loud(self):
        provider = FakeProvider(self.tmp.name, resume_works=False)
        self.addCleanup(provider.close)
        result = self.run_runner(
            PAUSE_PROVIDER="1",
            PAUSE_PROVIDER_SOCKET=provider.socket_path,
            PAUSE_PROVIDER_PORT=str(provider.port),
            FAKE_SERVE_COUNT="2",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(provider.frames, ["pause_request", "resume_request", "resume_request"])
        self.assertIn("RESUME FAILED", result.stderr)


if __name__ == "__main__":
    unittest.main()
