from __future__ import annotations

import importlib.util
import io
import json
import os
import random
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "measure-pool-rejection-timing-floor.py"


def load_module():
    spec = importlib.util.spec_from_file_location("measure_pool_rejection_timing_floor", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def passing_samples() -> dict[str, list[float]]:
    return {
        "unknown": [50.2, 50.4, 50.1, 50.3, 50.2, 50.5, 50.0, 50.4],
        "unauthorized": [50.3, 50.1, 50.4, 50.2, 50.0, 50.3, 50.2, 50.1],
        "disabled": [50.1, 50.2, 50.3, 50.4, 50.2, 50.1, 50.5, 50.0],
    }


class PoolRejectionTimingFloorTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()

    def test_offline_samples_do_not_claim_production_remeasure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "samples.json"
            path.write_text(json.dumps(passing_samples()))
            buf = io.StringIO()
            with redirect_stdout(buf):
                code = self.mod.main(["--samples-json", str(path), "--environment", "local"])
            self.assertEqual(code, 0)
            self.assertIn('"production_remeasure_complete": false', buf.getvalue())

    def test_offline_result_json_marks_remeasure_incomplete(self):
        timing = self.mod.evaluate_samples(passing_samples(), floor_ms=50, method="offline_samples_json")
        result = self.mod.build_result(
            timing,
            environment="local",
            source="samples-json",
            production_host=False,
            allow_production=False,
        )
        self.assertTrue(timing["within_r007_bounds"])
        self.assertFalse(result["production_remeasure_complete"])
        self.assertEqual(result["environment"], "local")
        self.assertEqual(result["source"], "samples-json")
        self.assertGreaterEqual(result["pool_rejection_timing"]["floor_ms"], 50)

    def test_refuses_production_host_without_allow(self):
        with self.assertRaises(SystemExit) as raised:
            self.mod.main(
                [
                    "--base-url",
                    "https://coordinator.malibu.tech",
                    "--environment",
                    "production",
                    "--pool-id",
                    "pool-a",
                    "--authorized-account",
                    "acct-a",
                    "--unauthorized-account",
                    "acct-b",
                ]
            )
        self.assertIn("refusing production host", str(raised.exception))

    def test_refuses_missing_source(self):
        with self.assertRaises(SystemExit) as raised:
            self.mod.main([])
        self.assertIn("provide --samples-json", str(raised.exception))

    def test_tail_sample_is_not_ignored_by_p99(self):
        samples = {
            "unknown": [50.0] * 15 + [500.0],
            "unauthorized": [50.0] * 16,
            "disabled": [50.0] * 16,
        }
        timing = self.mod.evaluate_samples(samples, floor_ms=50, method="operator_http_probe")
        self.assertFalse(timing["within_r007_bounds"])
        self.assertGreater(timing["p99_delta_ms"], 25)
        result = self.mod.build_result(
            timing,
            environment="production",
            source="http",
            production_host=True,
            allow_production=True,
        )
        self.assertFalse(result["production_remeasure_complete"])

    def test_distinguishable_samples_fail_bounds(self):
        samples = {
            "unknown": [50.0] * 8,
            "unauthorized": [80.0] * 8,
            "disabled": [50.0] * 8,
        }
        timing = self.mod.evaluate_samples(samples, floor_ms=50, method="offline_samples_json")
        self.assertFalse(timing["within_r007_bounds"])
        self.assertGreater(timing["p95_delta_ms"], 15)

    def test_samples_below_floor_fail_closed(self):
        samples = passing_samples()
        samples["unknown"][0] = 10.0
        with self.assertRaises(SystemExit) as raised:
            self.mod.evaluate_samples(samples, floor_ms=50, method="offline_samples_json")
        self.assertIn("below floor_ms", str(raised.exception))

    def test_production_remeasure_complete_requires_http_production_host(self):
        timing = self.mod.evaluate_samples(passing_samples(), floor_ms=50, method="operator_http_probe")
        local_http = self.mod.build_result(
            timing,
            environment="production",
            source="http",
            production_host=False,
            allow_production=True,
        )
        self.assertFalse(local_http["production_remeasure_complete"])
        complete = self.mod.build_result(
            timing,
            environment="production",
            source="http",
            production_host=True,
            allow_production=True,
        )
        self.assertTrue(complete["production_remeasure_complete"])
        json_on_prod_env = self.mod.build_result(
            timing,
            environment="production",
            source="samples-json",
            production_host=True,
            allow_production=True,
        )
        self.assertFalse(json_on_prod_env["production_remeasure_complete"])


class _PoolUnavailableHandler(BaseHTTPRequestHandler):
    seen: list[tuple[str, str, str]] = []

    def do_POST(self):  # noqa: N802 - http.server API
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        type(self).seen.append(
            (
                self.headers.get("Authorization", ""),
                self.headers.get("X-MacProvider-Account", ""),
                self.headers.get("X-MacProvider-Pool-Select", ""),
            )
        )
        body = b'{"error":{"code":"pool_unavailable","message":"Pool unavailable"}}'
        self.send_response(503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return


class _FakeHTTPResponse:
    def __init__(self, *, status: int, body: bytes):
        self.status = status
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self) -> bytes:
        return self.body


class _FakeOpener:
    def __init__(self, response: _FakeHTTPResponse):
        self.response = response
        self.requests = []

    def open(self, request, *, timeout):
        self.requests.append((request, timeout))
        return self.response


class _RedirectingHandler(BaseHTTPRequestHandler):
    status_code = 302
    location = ""
    seen: list[tuple[str, str, str]] = []

    def do_POST(self):  # noqa: N802 - http.server API
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        type(self).seen.append(
            (
                self.headers.get("Authorization", ""),
                self.headers.get("X-MacProvider-Account", ""),
                self.headers.get("X-MacProvider-Pool-Select", ""),
            )
        )
        self.send_response(type(self).status_code)
        self.send_header("Location", type(self).location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        return


class _RedirectTargetHandler(BaseHTTPRequestHandler):
    seen: list[tuple[str, str, str, str]] = []

    def do_GET(self):  # noqa: N802 - http.server API
        self._record()

    def do_POST(self):  # noqa: N802 - http.server API
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self._record()

    def _record(self):
        type(self).seen.append(
            (
                self.command,
                self.path,
                self.headers.get("Authorization", ""),
                self.headers.get("X-MacProvider-Account", ""),
            )
        )
        body = b'{"error":{"code":"pool_unavailable","message":"target should not be reached"}}'
        self.send_response(503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return


class PoolRejectionTimingCredentialTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()

    def args(self, argv):
        return self.mod.parse_args(argv)

    def test_bearer_keys_come_from_named_env_vars(self):
        with mock.patch.dict(os.environ, {"AUTH_KEY": "sk-auth", "UNAUTH_KEY": "sk-other"}):
            plan = self.mod.plan_from_args(
                self.args(
                    [
                        "--pool-id", "pausedpoolxxxxxxxxxxxx",
                        "--authorized-key-env", "AUTH_KEY",
                        "--unauthorized-key-env", "UNAUTH_KEY",
                    ]
                )
            )
        self.assertEqual(plan["unknown"][0], {"Authorization": "Bearer sk-auth"})
        self.assertEqual(plan["disabled"], ({"Authorization": "Bearer sk-auth"}, "pausedpoolxxxxxxxxxxxx"))
        self.assertEqual(plan["unauthorized"], ({"Authorization": "Bearer sk-other"}, "pausedpoolxxxxxxxxxxxx"))

    def test_unauthorized_pool_id_covers_class_with_one_credential(self):
        with mock.patch.dict(os.environ, {"AUTH_KEY": "sk-auth"}):
            plan = self.mod.plan_from_args(
                self.args(
                    [
                        "--pool-id", "pausedpoolxxxxxxxxxxxx",
                        "--unauthorized-pool-id", "foreignpoolxxxxxxxxxxx",
                        "--authorized-key-env", "AUTH_KEY",
                    ]
                )
            )
        self.assertEqual(plan["unauthorized"], ({"Authorization": "Bearer sk-auth"}, "foreignpoolxxxxxxxxxxx"))

    def test_unset_key_env_fails_closed_without_echoing_a_value(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(SystemExit) as raised:
                self.mod.plan_from_args(
                    self.args(["--pool-id", "p", "--unauthorized-pool-id", "q", "--authorized-key-env", "MISSING_KEY"])
                )
        self.assertIn("MISSING_KEY", str(raised.exception))

    def test_mixed_credential_modes_refused(self):
        with mock.patch.dict(os.environ, {"AUTH_KEY": "sk-auth"}):
            with self.assertRaises(SystemExit) as raised:
                self.mod.plan_from_args(
                    self.args(
                        ["--pool-id", "p", "--authorized-key-env", "AUTH_KEY", "--unauthorized-account", "acct-b"]
                    )
                )
        self.assertIn("not both", str(raised.exception))

    def test_unauthorized_class_requires_a_source(self):
        with mock.patch.dict(os.environ, {"AUTH_KEY": "sk-auth"}):
            with self.assertRaises(SystemExit) as raised:
                self.mod.plan_from_args(self.args(["--pool-id", "p", "--authorized-key-env", "AUTH_KEY"]))
        self.assertIn("--unauthorized-pool-id", str(raised.exception))

    def test_lab_account_header_mode_kept(self):
        plan = self.mod.plan_from_args(
            self.args(["--pool-id", "p", "--authorized-account", "acct-a", "--unauthorized-account", "acct-b"])
        )
        self.assertEqual(plan["unauthorized"], ({"X-MacProvider-Account": "acct-b"}, "p"))
        self.assertEqual(plan["disabled"], ({"X-MacProvider-Account": "acct-a"}, "p"))

    def test_measure_http_sends_bearer_and_shuffles_class_order(self):
        _PoolUnavailableHandler.seen = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), _PoolUnavailableHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            plan = self.mod.class_plan(
                unknown_pool_id="unknownpoolxxxxxxxxxxx",
                pool_id="pausedpoolxxxxxxxxxxxx",
                unauthorized_pool_id="foreignpoolxxxxxxxxxxx",
                authorized={"Authorization": "Bearer sk-auth"},
                unauthorized=None,
            )
            measured = self.mod.measure_http(
                f"http://127.0.0.1:{server.server_address[1]}",
                plan=plan,
                samples=8,
                timeout_s=5,
                rng=random.Random(7),
            )
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual({k: len(v) for k, v in measured.items()}, {"unknown": 8, "unauthorized": 8, "disabled": 8})
        seen = _PoolUnavailableHandler.seen
        self.assertEqual(len(seen), 24)
        self.assertTrue(all(auth == "Bearer sk-auth" and account == "" for auth, account, _ in seen))
        pool_to_class = {
            "unknownpoolxxxxxxxxxxx": "unknown",
            "foreignpoolxxxxxxxxxxx": "unauthorized",
            "pausedpoolxxxxxxxxxxxx": "disabled",
        }
        rounds = [tuple(pool_to_class[pool] for _, _, pool in seen[i : i + 3]) for i in range(0, 24, 3)]
        self.assertTrue(all(sorted(r) == ["disabled", "unauthorized", "unknown"] for r in rounds))
        self.assertGreater(len(set(rounds)), 1, "class order must vary across rounds")

    def test_measure_http_rejects_404_even_with_pool_unavailable_code(self):
        plan = self.mod.class_plan(
            unknown_pool_id="unknownpoolxxxxxxxxxxx",
            pool_id="pausedpoolxxxxxxxxxxxx",
            unauthorized_pool_id="foreignpoolxxxxxxxxxxx",
            authorized={"Authorization": "Bearer sk-auth"},
            unauthorized=None,
        )
        body = b'{"error":{"code":"pool_unavailable","message":"Pool unavailable"}}'
        fake_opener = _FakeOpener(_FakeHTTPResponse(status=404, body=body))
        with mock.patch.object(self.mod.ssl, "create_default_context", return_value=object()), mock.patch.object(
            self.mod,
            "build_url_opener",
            return_value=fake_opener,
        ):
            with self.assertRaises(SystemExit) as raised:
                self.mod.measure_http(
                    "https://gateway.example",
                    plan=plan,
                    samples=1,
                    timeout_s=5,
                    rng=random.Random(1),
                )
        self.assertIn("status=404", str(raised.exception))
        self.assertEqual(len(fake_opener.requests), 1)

    def test_measure_http_rejects_incidental_pool_unavailable_message(self):
        plan = self.mod.class_plan(
            unknown_pool_id="unknownpoolxxxxxxxxxxx",
            pool_id="pausedpoolxxxxxxxxxxxx",
            unauthorized_pool_id="foreignpoolxxxxxxxxxxx",
            authorized={"Authorization": "Bearer sk-auth"},
            unauthorized=None,
        )
        body = b'{"error":{"code":"rate_limited","message":"mentions pool_unavailable only in text"}}'
        fake_opener = _FakeOpener(_FakeHTTPResponse(status=503, body=body))
        with mock.patch.object(self.mod.ssl, "create_default_context", return_value=object()), mock.patch.object(
            self.mod,
            "build_url_opener",
            return_value=fake_opener,
        ):
            with self.assertRaises(SystemExit) as raised:
                self.mod.measure_http(
                    "https://gateway.example",
                    plan=plan,
                    samples=1,
                    timeout_s=5,
                    rng=random.Random(1),
                )
        self.assertIn("error.code='rate_limited'", str(raised.exception))
        self.assertEqual(len(fake_opener.requests), 1)

    def test_measure_http_reuses_one_tls_context_for_all_samples(self):
        plan = self.mod.class_plan(
            unknown_pool_id="unknownpoolxxxxxxxxxxx",
            pool_id="pausedpoolxxxxxxxxxxxx",
            unauthorized_pool_id="foreignpoolxxxxxxxxxxx",
            authorized={"Authorization": "Bearer sk-auth"},
            unauthorized=None,
        )
        body = b'{"error":{"code":"pool_unavailable","message":"Pool unavailable"}}'
        tls_context = object()
        fake_opener = _FakeOpener(_FakeHTTPResponse(status=503, body=body))
        with mock.patch.object(self.mod.ssl, "create_default_context", return_value=tls_context) as make_context:
            with mock.patch.object(
                self.mod,
                "build_url_opener",
                return_value=fake_opener,
            ) as build_opener:
                measured = self.mod.measure_http(
                    "https://gateway.example",
                    plan=plan,
                    samples=2,
                    timeout_s=5,
                    rng=random.Random(1),
                )
        self.assertEqual(make_context.call_count, 1)
        build_opener.assert_called_once_with(tls_context)
        self.assertEqual(len(fake_opener.requests), 6)
        self.assertEqual({k: len(v) for k, v in measured.items()}, {"unknown": 2, "unauthorized": 2, "disabled": 2})

    def test_measure_http_rejects_cross_origin_redirects_without_forwarding_credentials(self):
        plan = self.mod.class_plan(
            unknown_pool_id="unknownpoolxxxxxxxxxxx",
            pool_id="pausedpoolxxxxxxxxxxxx",
            unauthorized_pool_id="foreignpoolxxxxxxxxxxx",
            authorized={"Authorization": "Bearer sk-auth"},
            unauthorized=None,
        )
        for status_code in (301, 302, 303, 307, 308):
            with self.subTest(status_code=status_code):
                _RedirectTargetHandler.seen = []
                target = ThreadingHTTPServer(("127.0.0.1", 0), _RedirectTargetHandler)
                target_thread = threading.Thread(target=target.serve_forever, daemon=True)
                target_thread.start()
                try:
                    _RedirectingHandler.status_code = status_code
                    _RedirectingHandler.location = f"http://127.0.0.1:{target.server_address[1]}/redirected"
                    _RedirectingHandler.seen = []
                    origin = ThreadingHTTPServer(("127.0.0.1", 0), _RedirectingHandler)
                    origin_thread = threading.Thread(target=origin.serve_forever, daemon=True)
                    origin_thread.start()
                    try:
                        with self.assertRaises(SystemExit) as raised:
                            self.mod.measure_http(
                                f"http://127.0.0.1:{origin.server_address[1]}",
                                plan=plan,
                                samples=1,
                                timeout_s=5,
                                rng=random.Random(1),
                            )
                    finally:
                        origin.shutdown()
                        origin.server_close()
                finally:
                    target.shutdown()
                    target.server_close()
                self.assertIn(f"status={status_code}", str(raised.exception))
                self.assertEqual(_RedirectTargetHandler.seen, [])
                self.assertEqual(len(_RedirectingHandler.seen), 1)
                self.assertEqual(_RedirectingHandler.seen[0][0], "Bearer sk-auth")


if __name__ == "__main__":
    unittest.main()
